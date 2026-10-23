# Corvid demo runbook

Three runnable demos ship with the engine. All are **fully synthetic** —
invented clinics ("Broken Rock", "Tallgrass"), invented patients
("Riverstone, Dawn (synthetic)"), invented dollar amounts; no real tribe,
facility, person, or PHI. The demos themselves run **offline**: no live EHR,
no cloud credentials, no network calls. The only network use is the one-time
`bundle install` an entry point runs on a checkout whose gems are not yet
installed; once gems are cached, everything is offline.

## Prerequisites

- Ruby 4.0.2 (`.ruby-version`), Bundler
- PostgreSQL running locally, with permission to create databases
  (`corvid_dummy_development`)

That's it. Each entry point installs gems, prepares the development database,
resets any prior demo rows, and runs the demo. Nothing else to seed by hand —
including the CMS rate data the MLR demo prices against, which is seeded
in-process.

The demos use the **development** database. Each entry point forces
`RAILS_ENV=development` and refuses to start if a different `RAILS_ENV` is
inherited from your shell (for example one set up for the suites). A
`DATABASE_URL` is used exactly as given, so make sure it names a development
database — never `corvid_dummy_test`.

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

Each entry point clears its own prior demo rows before it runs, so
**re-running the script is enough**, and the demos can run in any order (the
PRC demo and the overlay share the Broken Rock facility; the overlay reset
clears what the PRC demo leaves, while the PRC demo clears only its own case,
so overlay rows stay until the next overlay run). All
three entry points are idempotent — a second run produces the same numbers
and does not duplicate rows. (Calling the rake task `demo:migrate` directly,
without `demo:migration_reset` first, appends a fresh audit `Determination`
per hero on each run; the entry point resets first for that reason.)

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

If you set `DATABASE_URL`, drop the database it names instead (with the same
host, role and password).

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

An unknown name is an error, not a silent pass.

Runs every demo end to end and asserts the beats the audience is supposed to
see are actually present, so demo rot fails in CI instead of on stage. The
`demo-smoke` job in `.github/workflows/ci.yml` runs it on every PR and is
**independent of the test job** — the demos must stay runnable even while the
suite is red.
