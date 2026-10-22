# Corvid

Open-source Rails engine for the coordination, adjudication, and billing layer that sits **between an EHR and its payers** — the connective tissue for programs that manage and pay for care delivered *outside* the clinic.

Corvid runs service authorization and referral workflows, eligibility and payer-of-last-resort verification, budget obligations, and **Medicare-Like-Rates repricing** of purchased/referred-care claims. It's **EHR-agnostic** (any FHIR R4 server via pluggable adapters) and **chart-free** — it stores **no PHI at rest**; all clinical and identifying data lives in the host's vault, resolved through the adapter interface.

## Use cases

- **PRC/CHS** — IHS/tribal Purchased/Referred Care referral authorization **and Medicare-Like-Rates repricing** of outside claims
- **State Medicaid** — prior authorization and care coordination across many tribes/facilities
- **H.R. 1 community-engagement exemption** — record the answer an Indian health provider gave about whether a person is eligible for services from an Indian health provider. Corvid stores no determination of its own.
- **Cross-org coordination** — a de facto HIE control plane that lets programs share the right data without warehousing each other's records
- **City homelessness** — housing placement and service delivery
- **Foster care** — case management across counties and states

## Status

Pre-1.0. The engine is being extracted from a production Rails app and is not yet recommended for new production deployments. The API will change before 1.0.

## Installation

```ruby
# Gemfile
gem "corvid", git: "https://github.com/lakeraven/corvid"
```

Mount the engine in your routes:

```ruby
# config/routes.rb
mount Corvid::Engine => "/corvid"
```

Run migrations:

```bash
rails db:migrate
```

## Configuration

```ruby
# config/initializers/corvid.rb
Corvid.configure do |c|
  # EHR adapter (REQUIRED in production)
  c.adapter = Corvid::Adapters::FhirAdapter.new(
    base_url: ENV["FHIR_BASE_URL"]
  )

  # PHI sanitizer for log messages (REQUIRED in production — defaults to redact-all)
  c.phi_sanitizer = ->(msg) { PhiSanitizer.redact(msg) }

  # Provenance hooks (optional)
  c.on_provenance = ->(**attrs) { Provenance.create!(**attrs) }
  c.fetch_provenance = ->(**attrs) { Provenance.where(**attrs).to_a }
end
```

In each request (web or job), set the tenant context:

```ruby
class ApplicationController < ActionController::Base
  around_action :set_corvid_tenant

  private

  def set_corvid_tenant
    Corvid.with_tenant(current_account.identifier) { yield }
  end
end
```

**Background jobs MUST set tenant context explicitly.** Without it, queries against `Corvid::Case`, `Corvid::PrcReferral`, etc. will raise `Corvid::MissingTenantContextError`.

## Architecture

```
Host App (e.g. lakeraven-ehr, corvid-saas)
  ├── Corvid::Engine (this gem, public)
  │   ├── Models: Case, PrcReferral, Task, CareTeam, etc.
  │   ├── Services: AuthorizationWizard, CommitteeReviewSyncService, etc.
  │   └── Adapters::Base contract → MockAdapter / FhirAdapter
  └── corvid-adapters (private, optional)
      └── Corvid::Adapters::Clearinghouse, EHR, RPMS, etc.
```

## Adapters

| Adapter | Use case |
|---|---|
| `Corvid::Adapters::MockAdapter` | Dev/test only — **not a security boundary** |
| `Corvid::Adapters::FhirAdapter` | Generic FHIR R4 — works with any compliant server |
| Vendor adapters | Implement `Corvid::Adapters::Base` for proprietary EHRs (private repos) |

### Adapter contract tests

Every adapter — in this repo or a private vendor repo — must include the `AdapterContractTests` module from `test/support/adapter_contract_tests.rb` in a test class and pass it to merge.

The including class defines:

- `contract_adapter`
- `contract_seed!` — seeds synthetic records and returns a Hash with every key in `AdapterContractTests::REQUIRED_SEED_KEYS` (`*_identifier` names per [ADR 0001](docs/adr/0001-id-vs-identifier-naming.md)). Synthetic data only ([ADR 0003](docs/adr/0003-phi-tokenization.md))
- `contract_unsupported` — a Hash of `Corvid::Adapters::Base` method => one-line reason. Listed methods must raise `NotImplementedError`
- `contract_fail_closed_stubs` (optional) — a Hash of method => reason for methods that return a documented "unsupported" value instead of raising (for example FhirAdapter's `submit_claim`). The seeded call must not report success; the shape and unknown-identifier checks still run. It must not overlap `contract_unsupported`

Every seeded check runs for every implemented method. There are no seed flags that switch a check off: an adapter that cannot serve one lists the method in `contract_unsupported`. Writes are read back, so a write that reports success must be visible to the matching read (`create_referral` to `find_referral`, `record_payment` to `get_payments`, and so on).

Each `Base` method is in exactly one unknown-identifier category:

- `UNKNOWN_IDENTIFIER_RULES` — an unknown identifier fails closed: nil, `[]`, false or a non-success result, never eligible, verified or refunded
- `NO_IDENTIFIER_METHODS` — the method takes no identifier
- `DECLINED_UNKNOWN_IDENTIFIER_CHECKS` — writes the host owns the registry for (for example `create_referral`), each with a reason

A public method added to `Corvid::Adapters::Base` is covered automatically. It fails until it has a `CONTRACT_CALLS` entry, a shape case and an unknown-identifier category.

Examples: `test/corvid/adapters/*_contract_test.rb`.

The module lives under `test/`, which the packaged gem does not ship. A vendor repo loads it from a git checkout of corvid, for example `require File.join(Gem.loaded_specs["corvid"].full_gem_path, "test/support/adapter_contract_tests")` with corvid as a Bundler git dependency.

## Tenancy model

Corvid supports a two-level tenancy hierarchy:

- **Tenant** (required, hard isolation boundary) — typically maps to one EHR instance
- **Facility** (optional, soft classification) — typically maps to one EHR division

Examples (illustrative):

| Tenant | Facilities |
|---|---|
| A tribal health program | Main clinic, Behavioral Health, Satellite clinic |
| A multi-state nonprofit | State A, State B, State C |
| A state Medicaid program | Many tribes/clinics (each a facility) |

Cross-facility data sharing within a tenant is supported. Cross-tenant queries are not.

## PHI handling

Per [ADR 0003](docs/adr/0003-phi-tokenization.md), Corvid stores **no PHI at rest**. All identifying and clinical data is tokenized:

- Patient names, DOBs, MRNs → adapter-resolved (in-memory only)
- Notes, rationale, reasons → vault tokens (resolved on demand)
- Insurance policy numbers → vault tokens
- Workflow dates → stored (combination risk documented)

A Corvid Postgres dump viewed without vault access reveals no PHI — only opaque tokens, workflow state, counts, and timestamps.

The `phi_sanitizer` hook defaults to fail-safe redact-all. Forgetting to configure it will not increase PHI exposure in logs.

## CMS fee schedule data

Corvid ships with a derived snapshot of the Medicare Physician Fee Schedule (RVUs, GPCIs, conversion factors) so that `PrcOverpaymentAnalyzer` can compute professional-service Medicare-equivalent rates without reading raw CMS files at runtime.

**Default path — load the bundled snapshot:**

```bash
rails db:migrate
rake cms:snapshot:load
```

This populates `corvid_fee_schedule_entries` with all available years from the snapshot at `db/seeds/cms_fee_schedules.csv.gz`. Snapshot integrity is verified by SHA256 on load.

**Advanced — re-ingest from CMS source files:**

Only needed when CMS publishes a new year and you want to refresh the snapshot. Source files (PPRRVU\*.csv and GPCI\*.csv) live under `db/data/cms_fee_schedules/{year}/` and are not committed — they're large, re-fetchable, and accumulate. The canonical source zips are mirrored in the [`cms-fee-schedules-v1` GitHub Release](https://github.com/lakeraven/corvid/releases/tag/cms-fee-schedules-v1), or download fresh from [CMS PFS Relative Value Files](https://www.cms.gov/medicare/payment/fee-schedules/physician/pfs-relative-value-files).

```bash
rake cms:fetch[2026]            # download + extract one year
rake cms:fetch_all              # mirror everything (2007-2026)
rake cms:import[2026]           # re-ingest one year into the DB
rake cms:import_all             # re-ingest every year directory found
rake cms:snapshot:export        # regenerate db/seeds/cms_fee_schedules.csv.gz
```

```bash
rake cms:import[2026]          # one year
rake cms:import_all            # every year directory found on disk
rake cms:snapshot:export       # regenerate db/seeds/cms_fee_schedules.csv.gz
```

Each `cms:import` writes a `Corvid::CmsFeeScheduleRelease` record capturing the source file checksum and parser version, so the provenance of every imported year is auditable.

## Architectural decisions

| ADR | Topic |
|---|---|
| [0001](docs/adr/0001-id-vs-identifier-naming.md) | Reserve `id`/`*_id` for Rails keys; use `identifier`/`*_identifier` for external references |
| [0002](docs/adr/0002-architectural-foundations.md) | Tenancy, table prefixes, string enums, hooks, namespacing |
| [0003](docs/adr/0003-phi-tokenization.md) | PHI tokenization (Stripe-style for HIPAA) |
| [0008](docs/adr/0008-indian-health-eligibility-inquiry.md) | Inquiry for eligibility for services from an Indian health provider |

## Demos

Three fully synthetic demos ship with the engine (offline once gems are
installed) — a stock-FHIR multi-clinic PRC + MLR overlay, a narrated PRC happy
path, and a governed patient-data migration. Each is one command from a fresh checkout:

```bash
bin/demo-overlay
bin/demo-prc
bin/demo-prc-migration
```

Runbook: [`docs/demo.md`](docs/demo.md).

## Development

```bash
bundle install
cd test/dummy && bundle exec rails db:create db:migrate && cd ../..
bundle exec rake test
```

## License

MIT
