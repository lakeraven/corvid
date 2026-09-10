# Corvid demo runbook

Three runnable demos ship with the engine. All are **fully synthetic** —
invented clinics ("Broken Rock", "Tallgrass"), invented patients
("Riverstone, Dawn (synthetic)"), invented dollar amounts; no real tribe,
facility, person, or PHI. All run **offline**: no network, no live EHR, no
cloud credentials.

## Prerequisites

- Ruby 4.0.2 (`.ruby-version`), Bundler
- PostgreSQL running locally, with permission to create databases
  (`corvid_dummy_development`)

That's it. Each entry point installs gems, prepares the development database,
resets any prior demo rows, and runs the demo. Nothing else to seed by hand —
including the CMS rate data the MLR demo prices against, which is seeded
in-process.

The demos use the **development** database. They never touch the test database
and never rewrite `test/dummy/db/schema.rb`.

`test/dummy/config/database.yml` names no user, so it connects as your OS user
over the local socket. If your Postgres needs a role, host, or password, set
`DATABASE_URL` and every entry point picks it up:

```bash
DATABASE_URL=postgres://user:pass@localhost:5432/corvid_dummy_development bin/demo-overlay
```

## 1. Stock-FHIR overlay demo — multi-clinic PRC + MLR

```bash
bin/demo-overlay
```

**What the audience sees.** Two synthetic clinics on two different source EHRs
export plain FHIR R4. Corvid ingests both through the generic `FhirAdapter` —
no vendor-specific code — PRC eligibility checklists auto-populate from the
FHIR payload, and every purchased/referred-care charge is repriced to its
**Medicare-Like Rate** using real CMS CY2026 PFS/OPPS data through the
production `PrcOverpaymentAnalyzer`. It closes on per-clinic and consortium
`billed -> MLR -> $ recovered` totals and a CEHRT-safety note (Corvid is a
read-only overlay; the certified EHR stays the system of record).

Deeper background: [`docs/demo_fhir_overlay.md`](demo_fhir_overlay.md).

## 2. Narrated PRC happy path

```bash
bin/demo-prc
```

**What the audience sees.** One referral walked end to end — registration,
eligibility review with tribal enrollment verification, payer-of-last-resort
check, management approval, alternate-resource review, budget check, and
authorization with a reserved obligation. Every beat is tagged `[REAL]`
(engine-native, PG-backed) or `[MOCK]` (offline adapter), so the honesty line
between shipped engine and stubbed backend is visible on screen.

This is the best lead demo for a clinical/PRC audience — it is the workflow a
PRC clerk actually performs. Walkthrough notes:
[`docs/demo_prc_walkthrough.md`](demo_prc_walkthrough.md).

## 3. Governed PRC migration demo

```bash
bin/demo-prc-migration
```

**What the audience sees.** Two synthetic patients staged for migration to a
new system. The consented patient **migrates** — a minimum-necessary bundle is
posted to the injected target (an in-process stub here; a host injects a real
transport for a live relay). The patient without Data Governance Board consent
is **halted**. Both outcomes are recorded as audit `Determination`s.

## Reset between runs

Each entry point resets before it runs, so **re-running the script is enough**.
All three demos are also idempotent — a second run without a reset produces the
same numbers and does not duplicate rows.

To reset by hand:

```bash
cd test/dummy
bin/rails demo:overlay_reset
bin/rails demo:migration_reset
```

`bin/demo-prc` has no reset task: it destroys its own prior case at the top of
each run.

To start completely clean:

```bash
dropdb corvid_dummy_development && bin/demo-overlay
```

## Rake tasks behind the entry points

The scripts are thin wrappers around rake tasks that run in `test/dummy` — or
in any host app that mounts the engine:

| Task | Purpose |
|---|---|
| `demo:overlay` | Stock-FHIR overlay demo |
| `demo:overlay_reset` | Clear the overlay demo's tenants |
| `demo:prc` | Narrated PRC happy path |
| `demo:migrate` | Governed migration demo |
| `demo:migration_reset` | Clear the migration demo's seeded cases |

## Smoke check

```bash
bin/demo-smoke              # all three
bin/demo-smoke overlay      # one of: overlay, prc-migration, prc
```

Runs every demo end to end and asserts the beats the audience is supposed to
see are actually present, so demo rot fails in CI instead of on stage. The
`demo-smoke` job in `.github/workflows/ci.yml` runs it on every PR and is
**independent of the test job** — the demos must stay runnable even while the
suite is red.

## Known environment issue

Under `json` 3.x, the Rails 8.1 schema dumper cannot dump a `json`/`jsonb`
column that has a default; it drops the whole table from `schema.rb` and leaves
a `# Could not dump table ... ArgumentError` comment in its place. In this repo
that hits `corvid_prc_eligibility_decisions`.

The demos are insulated from it — the dummy app's development environment sets
`config.active_record.dump_schema_after_migration = false`, so a demo run can
never rewrite the checked-in schema. Anything that runs `db:migrate` in another
environment still needs the real fix (pin `json` to `~> 2.21`, or a Rails
release that handles it).
