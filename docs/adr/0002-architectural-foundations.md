# ADR 0002: Architectural foundations

**Status:** Accepted
**Date:** 2026-04-06

## Context

Corvid is a Rails engine that manages case workflows for healthcare, social services, and benefit programs. It is consumed by host applications (lakeraven-ehr, corvid-saas, third-party integrators) and must work against multiple EHR backends via adapters. This ADR locks the architectural foundations needed for that goal.

## Decisions

### 1. Tenancy: two-level (Tenant > Facility), row-based

Corvid supports a two-level tenancy hierarchy:

```
Tenant (required, hard isolation boundary)
  └── Facility (optional, soft classification)
      └── Cases, Referrals, Tasks, etc.
```

**Rules:**
- Data CAN be shared across facilities **within a tenant** (reports, care coordination)
- Data CANNOT cross tenant boundaries — this is a compliance boundary, not a permission check
- One Tenant = one EHR instance (e.g. one IRIS instance per Tenant)
- One Facility = one Division within that EHR instance

**Real-world mapping:**

| Deployment | Tenant | Facility |
|---|---|---|
| Yakama Nation | Yakama Nation (1 IRIS instance) | White Swan, Behavioral Health, PCH (IRIS Divisions) |
| iFoster | iFoster | California, Nevada, Kentucky |
| Washington State | State of WA | 200+ tribes, each a Division |
| Santa Fe PRC | Santa Fe | Single facility (optional column) |

**Schema:**
- Every Case-domain table has `tenant_identifier` (string, NOT NULL) and `facility_identifier` (string, nullable)
- Compound index `(tenant_identifier, facility_identifier, ...)` on every table
- No `belongs_to :tenant` or `belongs_to :facility` — Tenant and Facility are host-owned concepts

**Enforcement (Option C — fail-loud):**

```ruby
class Corvid::Case < ActiveRecord::Base
  default_scope do
    tenant = Corvid.current_tenant_identifier
    raise Corvid::MissingTenantContextError, "current_tenant_identifier not set" unless tenant
    where(tenant_identifier: tenant)
  end

  scope :for_facility, ->(identifier) { where(facility_identifier: identifier) }
  scope :all_facilities_in_tenant, -> { all } # explicit "yes I want all facilities"
end
```

Queries without `Corvid.current_tenant_identifier` set raise immediately. There is **no `unscoped` escape hatch in v1**. Cross-tenant admin queries are deferred.

**Context propagation:**
- `Corvid.current_tenant_identifier` set via `ActiveSupport::CurrentAttributes`
- Hosts set it in `around_action` (web), `perform` (jobs), or explicitly in console
- **Background jobs MUST set tenant context.** Document this prominently.

**Polymorphic same-tenant validation:**

`Task#taskable` and `Determination#determinable` are polymorphic. Validate that the polymorphic target has the same `tenant_identifier`:

```ruby
validate :taskable_in_same_tenant

def taskable_in_same_tenant
  return unless taskable && tenant_identifier == taskable.tenant_identifier
  errors.add(:taskable, "must belong to the same tenant")
end
```

**Why row-based, not Apartment gem:**
- Engine compatibility (Apartment + Rails engines is fragile)
- Scale: Washington State has 200+ facilities; per-schema migrations don't scale
- IRIS already provides physical isolation at the EHR layer; corvid's job is logical isolation
- Cross-facility reporting within a tenant is a single WHERE clause vs cross-schema join

### 2. Table prefix: `corvid_*`

All engine-owned tables are prefixed `corvid_` to avoid collision with host tables that may share names (`cases`, `tasks`, etc.):

- `corvid_cases`
- `corvid_prc_referrals`
- `corvid_tasks`
- `corvid_care_teams`
- `corvid_care_team_members`
- `corvid_committee_reviews`
- `corvid_determinations`
- `corvid_alternate_resource_checks`
- `corvid_fee_schedules`

Each model declares `self.table_name = "corvid_xxx"`.

### 3. Enum storage: strings + Postgres CHECK constraints

All status/decision enums stored as strings, not integers:

```ruby
class Corvid::Case < ActiveRecord::Base
  enum :status, {
    active: "active",
    inactive: "inactive",
    closed: "closed"
  }
end
```

```ruby
# Migration
create_table :corvid_cases do |t|
  t.string :status, null: false, default: "active"
end
add_check_constraint :corvid_cases, "status IN ('active', 'inactive', 'closed')", name: "corvid_cases_status_check"
```

**Rationale:** debuggability, migration safety, FHIR alignment, AASM consistency. The CHECK constraint prevents bad data from raw SQL bypass.

### 4. Polymorphic class names

Polymorphic `*_type` columns store the namespaced class name as a string:

- `tasks.taskable_type` → `"Corvid::Case"` or `"Corvid::PrcReferral"`
- `determinations.determinable_type` → `"Corvid::Case"` or `"Corvid::PrcReferral"`

These strings are part of the engine's data contract. Renaming `Corvid::Case` would require a data migration. Document the upgrade path.

### 5. Namespace: flat under `Corvid::`

For v1, all engine classes live directly under `Corvid::`:

- `Corvid::Case`, `Corvid::PrcReferral`, `Corvid::Task`, etc.
- `Corvid::Adapters::Base`, `Corvid::Adapters::MockAdapter`
- `Corvid::Edi::Base`

**Revisit at ~20 models or when bounded contexts emerge** (e.g. workflow vs reporting split, then `Corvid::Workflow::*` and `Corvid::Reporting::*`).

`Corvid::Case` is the AR class name despite `case` being a Ruby keyword. As a constant, `Case` is legal. If Zeitwerk has trouble loading any path, add an inflection in the engine's `inflections.rb`.

### 6. No `Corvid::Facility` model

Facility is a host-owned concept. The engine does not store facility metadata (name, address, settings, RCIS params). Hosts that need rich facility data own their own `Facility` model.

The engine stores only `facility_identifier` (string), which the host maps to its own facility records.

### 7. Host hooks

The engine integrates with the host via three Configuration hooks:

```ruby
Corvid.configure do |c|
  c.adapter = Corvid::Adapters::FhirAdapter.new(...)

  # Audit/provenance
  c.on_provenance = ->(target_type:, target_id:, **attrs) { Provenance.create!(...) }
  c.fetch_provenance = ->(target_type:, target_id:) { Provenance.where(...).to_a }

  # PHI sanitization (see ADR 0003)
  c.phi_sanitizer = ->(message) { PhiSanitizer.sanitize(message) }
end
```

The engine never directly references host models like `Provenance`, `PhiSanitizer`, or `Patient`.

### 8. Jumpstart Account = Tenant (not Facility)

Where corvid is mounted in a Jumpstart Pro app:

- **Jumpstart Account** maps to **Corvid Tenant** (1:1 in v1)
- The Jumpstart Account slug or ID becomes `tenant_identifier`
- Multi-account-per-tenant or multi-tenant-per-account is deferred
- Facilities are a child concept under the Account, populated by host configuration

### 9. Database

- **Shared connection** with the host (Rails default)
- Multi-database engine connection deferred unless compliance or scale forces it
- Integer primary keys (Rails default); hosts can use UUIDs for their own tables independently

### 10. Engine entry point

```ruby
require "corvid"
```

Loads the engine and configuration. Hosts then call `Corvid.configure { |c| ... }` in an initializer.

## Consequences

### Positive
- Multi-tenant SaaS deployment is safe by default (raise on missing context)
- Engine works with any IRIS/EHR layout that maps to Tenant > Facility
- Schema isolation via prefix prevents host collisions
- String enums and CHECK constraints make production debugging easier
- Hooks decouple the engine from host-specific audit and PHI infrastructure

### Negative
- Background jobs must explicitly set tenant context — documentation and discipline required
- No cross-tenant escape hatch means cross-tenant reporting is deferred
- Host onboarding requires implementing three hooks at minimum
- Adding new bounded contexts later means namespace migration

### Alternatives considered

- **Apartment gem (schema-per-tenant).** Rejected — engine compatibility issues, doesn't scale to 200+ tenants per WA State, doesn't solve facility-level filtering, IRIS already provides physical isolation.
- **Tenant-as-FK to a corvid_tenants table.** Rejected — Tenant is a host concept (Jumpstart Account, etc.), engine should not own it.
- **Default `unscoped` for missing context.** Rejected — unsafe by default; PHI/compliance bug class we don't want to create.

## References

- ADR 0001 (id vs identifier naming)
- ADR 0003 (PHI tokenization)
- [Rails engines: isolated namespace](https://guides.rubyonrails.org/engines.html#main-isolate-namespace)
- [ActiveSupport::CurrentAttributes](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)
