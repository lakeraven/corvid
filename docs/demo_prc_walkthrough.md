# GM-5 · Corvid PRC demo — narrated happy path

Runbook for corvid#468 (Broken Rock Clinic demo, **hard deadline Aug 28 2026**).

Corvid is PG-only with no RPMS/AWS dependency, so this flow runs entirely
offline, in-process, against a local Postgres — no coordination needed with
the RPMS-on-YDB build (GM-1/GM-2) or the synthetic UIO dataset (GM-4, still
open as of this writing).

## What this demo proves

The **existing, tested** PRC engine walking one patient through the real
state machine end to end:

```
patient registration → eligibility + tribal enrollment verification →
PRC referral submission → checklist completion → management approval →
budget/obligation check → authorization
```

Every step below is either a real engine operation against Postgres, or a
clearly-marked mock/adapter response. Nothing here is aspirational — it's
the same code path exercised by `bundle exec cucumber features/prc/` (280
scenarios / 1769 steps, all green as of this branch).

## Reconciling the issue's pointers

corvid#468 said `features/prc/enrollment_demo.feature` + `db/baseroll_people.json`
+ `docs/demo.md` "already exist." On inspection:

- `features/prc/enrollment_demo.feature` and its adapter
  (`lib/corvid/adapters/enrollment_demo_adapter.rb`) **do** live in this repo
  (`corvid`) and pass (5 scenarios / 24 steps).
- `db/baseroll_people.json` and `docs/demo.md` actually live in the
  **`corvid-saas`** repo (the SaaS host app), not here. That runbook drives a
  two-process demo (baseroll + corvid-saas web UI) and its own paths are
  stale — it still references the retired Gas Town layout
  (`~/code/lakeraven/rpms/reference/corvid-saas`, `baseroll/mayor/rig`),
  which no longer exists post-flatten (see `d5728fe`). It also demos only the
  eligibility-decision slice, not the full referral → obligation lifecycle.
- The **GM-4 synthetic UIO panel** (rpms-ops#403) is still open and lives in
  RPMS, a different data plane than corvid's Postgres-backed engine. It is
  not wired into any corvid adapter today, so it is not usable for this demo
  yet.

Given that, this runbook adds a self-contained happy path **inside this
repo** using the engine's own `EnrollmentDemoAdapter` (offline, in-process,
zero external processes) — the most reliable path to a green, rehearsable
demo before Aug 28. `db/baseroll_people.json` / corvid-saas's `docs/demo.md`
remain a reasonable **richer, UI-driven fallback or follow-up** if the
corvid-saas web flow gets rehearsed too, but they are out of scope for this
issue's repo and are not verified here.

## Running it

```bash
cd corvid
bundle install                       # first time only
cd test/dummy && RAILS_ENV=test bin/rails db:prepare && cd ../..  # first time only

cd test/dummy
RAILS_ENV=test bin/rails demo:prc
```

The task is safely re-runnable — it deletes any prior demo `Case` for the
same patient/facility before creating fresh records.

To confirm the whole PRC surface (not just the demo path) is green:

```bash
cd corvid
bundle exec cucumber features/prc/     # 280 scenarios, 1769 steps
bundle exec rake test                  # unit/model/service suite
```

Both were run on this branch immediately before writing this runbook; see
the PR description for the pasted output.

## Adapter-mode matrix

| Adapter | How it's selected | Use |
|---|---|---|
| `Corvid::Adapters::EnrollmentDemoAdapter` | Explicitly configured by `demo:prc` (`Corvid.configure { \|c\| c.adapter = ... }`) | **This demo.** In-memory, in-process, seeded with 3 demo patients + 2 demo practitioners. No network calls. |
| `Corvid::Adapters::MockAdapter` | Default in test env (`features/support/env.rb` `Before` hook) | Used by the full cucumber/minitest suite. `EnrollmentDemoAdapter < MockAdapter`, just pre-seeded with named demo people instead of leaving the store empty. |
| A real vendor/FHIR adapter (e.g. `Lakeraven::Baseroll::CorvidAdapter`) | Set by host app config (`BASEROLL_API_URL`, etc.) — see corvid-saas's `docs/demo.md` | Production / corvid-saas web demo. Not exercised by this runbook. |

There is no env var to flip inside the `corvid` engine itself — the demo
adapter is wired directly in `lib/tasks/demo.rake`.

## Step-by-step: what the audience sees

Running `RAILS_ENV=test bin/rails demo:prc` prints a narrated transcript.
Each line is tagged `[REAL]` (actual engine/Postgres operation) or `[MOCK]`
(adapter-simulated external system).

1. **Patient registration**
   `[MOCK]` Patient identity resolved via adapter: `DEMO,ENROLLED MEMBER`
   (DOB 1985-06-15) — stands in for an RPMS/registration-system lookup.
   `[REAL]` `Corvid::Case` created in Postgres, `status=active`.

2. **PRC referral opened**
   `[REAL]` `Corvid::PrcReferral` created (`status=draft`), then
   `submit!` transitions it to `submitted`. This is the engine's real AASM
   state machine (`app/models/corvid/prc_referral.rb`).

3. **Eligibility review + tribal enrollment verification**
   `[REAL]` `begin_eligibility_review!` transitions to `eligibility_review`.
   `[MOCK]` `EligibilityChecklistService` auto-populates 3 of 7 checklist
   items (`enrollment_verified`, `identity_verified`, `residency_verified`)
   straight from the adapter — this is the audit-defense story: what used to
   be manual staff lookups (in a typical PRC eligibility audit, a large
   share of sampled files turn up missing enrollment, identity, or residency
   documentation — say roughly 10 / 50 / 25 out of a 100-file sample) is now
   automatic.
   `[REAL]` The remaining items are genuinely staff-entered and the demo
   enters them explicitly: `application_complete` and
   `clinical_necessity_documented`. For `insurance_verified`, the demo runs
   the on-demand payer check (`check_payer_eligibility!`) and reflects its
   actual result: if third-party coverage is found the check marks the item
   itself; only when the check finds none does staff document "no third-party
   coverage" (PRC is payer-of-last-resort). The demo never rubber-stamps this
   regardless of the check.

4. **Management approval + alternate resource review**
   `[REAL]` `request_management_approval!` (guarded — only fires once all
   non-approval checklist items are true), `approve_management!` (records
   the approving practitioner and flips the `management_approved` checklist
   item), `verify_alternate_resources!`.

5. **Obligation / budget check**
   `[REAL]` Referral cost set to $8,500 (under the $50,000 committee-review
   threshold, so this run takes the direct-authorization path — the
   committee-review branch is exercised separately by
   `features/prc/budget_availability.feature` and
   `features/prc/committee_review.feature`, not walked live here to keep the
   demo tight).
   `[MOCK]` `BudgetAvailabilityService` reads a CHS budget summary from the
   adapter ($750,000 remaining of $1,000,000 FY total) and reserves funds,
   returning an obligation id.
   `[REAL]` `complete_priority_assignment!` transitions the referral to
   `authorized` (no committee review required at this cost).

6. **Summary** — final referral status, checklist completion (100%),
   estimated cost, and the reserved obligation id, followed by an explicit
   REAL vs MOCKED recap.

## What's real vs mocked — the honest accounting

**Real** (runs against Postgres, exercised by the full test suite, would be
identical in production):
- `Corvid::Case` creation and tenant/facility scoping
- `Corvid::PrcReferral` AASM state machine (draft → submitted →
  eligibility_review → management_approval → alternate_resource_review →
  priority_assignment → authorized, or → committee_review / denied /
  deferred / cancelled on other paths)
- `Corvid::EligibilityChecklist` persistence and the 7-item CFR §200.303
  compliance model
- `Corvid::Determination` recording
- `Corvid::BudgetAvailabilityService` business logic (thresholds, fiscal
  year calculation, committee-review gating)
- Every rule that governs *when* a transition is allowed

**Mocked** (stands in for a system corvid doesn't own):
- Patient identity, tribal enrollment, identity-document, and residency
  verification (`EnrollmentDemoAdapter`, three canned demo people) — a real
  deployment wires a tribal enrollment system or FHIR server here (e.g.
  `Lakeraven::Baseroll::CorvidAdapter`, see corvid-saas)
- CHS budget summary and obligation creation — a real deployment wires the
  actual CHS ledger/RPMS system

Corvid's PHI-tokenization design (ADR 0003) means this boundary is
architectural, not a demo shortcut: the engine never stores PHI, so identity
and eligibility data legitimately have to come from an adapter in every
environment, demo or production.

## Confirmed green (this branch)

```
bundle exec cucumber features/prc/    → 280 scenarios (280 passed), 1769 steps (1769 passed)
bundle exec cucumber                  → 2490 steps (2490 passed)  [full suite]
bundle exec rake test                 → 981 runs, 2243 assertions, 0 failures, 0 errors, 0 skips
RAILS_ENV=test bin/rails demo:prc     → completes, referral status=authorized, checklist 100%
bundle exec rubocop lib/tasks/demo.rake → no offenses
```
