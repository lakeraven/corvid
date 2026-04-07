# Contributing to Corvid

Thanks for your interest. Corvid is a healthcare-adjacent engine with strict
compliance and isolation guarantees, so contributions follow a specific
workflow to keep those guarantees intact.

## Workflow

1. **Open an issue first** for anything beyond a typo or comment fix. We want
   to align on the design before code is written.
2. **Branch from `main`** with a descriptive name: `123-add-claim-port`,
   `fix-cross-tenant-leak`.
3. **TDD**: write the failing test first, then make it pass. Each commit
   should be a coherent red→green cycle.
4. **One PR per issue**. Smaller PRs review faster.
5. **CI must pass** before merge. Branch protection enforces this.

## Architectural rules (the things reviewers will check)

### ADR 0001 — Identifier naming

- Reserve `id` and `*_id` for Rails primary and foreign keys
- Use `identifier` and `*_identifier` for opaque external/vault tokens
- If you find yourself wanting to add `belongs_to :patient`, you're
  conflating the two. Patient is an adapter concept.

### ADR 0002 — Architectural foundations

- All engine tables are prefixed `corvid_*`
- All Case-domain tables include `tenant_identifier` (NOT NULL) and
  `facility_identifier` (nullable)
- Models include `Corvid::TenantScoped` — the default_scope raises if
  `Corvid::TenantContext.current_tenant_identifier` is unset
- **Background jobs MUST set tenant context.** No exceptions.
- Status enums are strings with PostgreSQL CHECK constraints
- Polymorphic models validate same-tenant association
- Engine code never references host models (`Patient`, `Provenance`, etc.)
  — use `Corvid.adapter` or configuration hooks

### ADR 0003 — PHI tokenization

- **Corvid stores no PHI at rest.** No `notes`, `reason`, `rationale`, or
  `name` text columns. Use `*_token` columns that resolve via the adapter.
- Patient identity (name, DOB, MRN) lives in the adapter/vault, retrieved
  in-memory only for the duration of a request
- All adapter exceptions must be sanitized via `Corvid.sanitize_phi(message)`
  before re-raising or logging
- Test fixtures use synthetic strings (`TEST,PATIENT 001`,
  `MOCK NOTE 001`) — never realistic-looking fake names
- The `Corvid.sanitize_phi` default is fail-safe redact-all. Don't change
  this default in tests.

## Adding an ADR

If your change introduces a substantive design decision, add an ADR:

1. Copy `docs/adr/0000-adr-template.md` to the next number
2. Fill in Context / Decision / Consequences
3. Reference the ADR from related code via comments and from the README
4. The ADR is part of your PR

## Test conventions

- `bundle exec rake test` runs the full suite (lib + models + services)
- `bundle exec rake test_lib` runs just the lib tests (no Rails)
- `bundle exec rake test_models` runs the dummy-app tests
- Tests must reset `Corvid::TenantContext` and `Corvid.adapter` between
  cases — this is done automatically in `test_helper.rb`
- Use `with_tenant("tnt_test") { ... }` to scope test bodies

## Reviewing a PR

Reviewers check:

- ADR compliance per the PR template checklist
- Test coverage matches the change scope
- No PHI leakage in logs, error messages, or commit messages
- Tenant isolation preserved
- Adapter contract not broken

## Releasing

Versioning follows [SemVer](https://semver.org/). Pre-1.0 minor versions
may include breaking changes. Tag and release notes go in CHANGELOG.md.

## Code of conduct

Be respectful. Healthcare touches vulnerable people; the same care applies
to the people building tools for it.
