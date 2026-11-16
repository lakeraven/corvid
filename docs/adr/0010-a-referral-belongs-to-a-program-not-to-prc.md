# ADR 0010: A referral's eligibility checks belong to its program, not to PRC

**Status:** Proposed
**Date:** 2026-11-16
**Issue:** #866
**Depends on:** ADR 0005 (adapter injection), ADR 0007 (the engine owns the referral loop and reads any EHR, open as #605)

## Context

Corvid checks a referral's alternate resources (Medicare A, B and D, Medicaid, VA, private
insurance, workers' comp, auto, liability, state and tribal programs, charity care) and its
eligibility before care is authorized. All of that hangs off one record, `Corvid::PrcReferral`:

| What | Where it attaches today |
|------|-------------------------|
| The 12 alternate-resource checks | `AlternateResourceCheck belongs_to :prc_referral`, unique per `prc_referral_id` |
| Verification, exhaustion and active coverage | `AlternateResourceService.verify_all(prc_referral)`, `all_exhausted?`, `has_active_coverage?` |
| Eligibility checklist | `PrcReferral has_one :eligibility_checklist` |
| Workflow | The `PrcReferral` AASM machine: submitted, eligibility review, management approval, alternate-resource review, priority assignment, committee review, exception review, then authorized, denied or deferred |
| EHR sync | `CHS_STATUS_MAP`, synced on authorize, deny and defer |

So a program that does not run Purchased/Referred Care cannot use the checks without also
taking PRC's workflow and policy: residency, medical priority, committee review and the CHS
status codes. Urban Indian organizations funded under Title V are the first such programs we
expect to serve. Whether any of them use PRC is not confirmed; this ADR assumes most do not.
They still need to know whether a patient has Medicaid or other coverage before the clinic
pays for care itself, and their rules differ from program to program.

What already exists to build on:

- `Corvid::ProgramRegistry` identifies programs by string code, ships IHS defaults, and lets a
  host register more programs from an initializer. `CaseProgram` validates enrollment against it.
- The alternate-resource checks call payers through the injected adapter (ADR 0005), so the
  payer calls themselves do not depend on PRC.
- ADR 0007 proposes one FHIR client that reads any certified EHR. A partner that does not run
  RPMS reaches Corvid through it.

## Decision

1. **The checks attach to a program-neutral referral.** A new `Corvid::ProgramReferral` record
   holds the case, the opaque service-request token (ADR 0001), the program code from
   `ProgramRegistry`, and a status. `AlternateResourceCheck` and `EligibilityChecklist` move from
   `belongs_to :prc_referral` to a polymorphic owner, so either record can carry them. The
   service methods take the owner, not a `PrcReferral`. The owner must be in the check's own
   tenant (the polymorphic same-tenant rule of ADR 0002), and the new status column is a string
   enum with a CHECK constraint.

2. **`PrcReferral` does not change behaviour.** It keeps its state machine, its PRC policy and
   its CHS sync. It becomes one owner of checks among two. No PRC data is migrated.

3. **A program declares its referral rules in the registry.** A registry entry gains an
   optional `referral_rules` block:
   - `required_resources`: which of the 12 resource types must be checked before a decision.
   - `last_resort`: whether the program pays only after the required resources are exhausted.
   - `exception_review`: which outcomes go to a staff review queue (for example, coverage found
     but unverifiable, or a check that could not run).
   A program with no `referral_rules` cannot create a `ProgramReferral`. That is refused, not
   defaulted to PRC's rules.

4. **The program-neutral workflow is short and staff decide.** `ProgramReferral` runs draft,
   checks, staff review, then authorized, denied or withdrawn. Corvid runs the checks and routes
   exceptions; a person at the program authorizes or denies. Corvid never authorizes on its own.

5. **Absence of data is never verification.** A required check that has not run, timed out or
   returned an error leaves the referral in staff review with the reason "could not determine".
   It is never counted as exhausted. "Not enrolled" is recorded only when the payer said so.

6. **No PRC policy applies outside PRC.** Residency, medical priority, committee review, the
   notification windows and the CHS status codes stay on `PrcReferral`. If a program wants one of
   them, it is added to `referral_rules` by a later ADR, not inherited.

## Consequences

### Positive
- An urban program can run eligibility and alternate-resource checks with its own rules,
  without a fork and without pretending to be a PRC program.
- The payer adapters and check logic are reused, not copied.
- PRC behaviour is untouched, so the existing PRC tests are the regression net.

### Negative
- Two referral records exist, and every caller of the check services changes its argument.
- The polymorphic owner needs a migration on `corvid_alternate_resource_checks` and
  `corvid_eligibility_checklists` (add owner type and id, backfill from `prc_referral_id`, then
  drop the old column in a separate release).
- Payer-of-last-resort rules for urban programs need counsel's reading before `last_resort: true`
  is shipped as a default for any program.

### Alternatives considered
- **Configure `PrcReferral` per program.** Rejected: PRC policy is spread through its state
  machine and callbacks, and switching parts of it off per program makes every PRC change a risk
  to every other program.
- **One generic `Referral` that replaces `PrcReferral`.** Rejected for now: it migrates all PRC
  data and rewrites a hard surface to gain nothing PRC needs. It can follow later if the two
  records converge.
- **Leave urban programs to a host application.** Rejected: eligibility rules would live outside
  the engine, which ADR 0007 already lists as a defect.

## Build order (filed as sub-issues of #866 once this is accepted)

1. Polymorphic owner on `AlternateResourceCheck` and `EligibilityChecklist`, with backfill. PRC
   behaviour unchanged.
2. `referral_rules` in `ProgramRegistry`, validated at registration; refuse a referral for a
   program without rules.
3. `ProgramReferral` record and its state machine.
4. Check services take an owner and apply the program's `required_resources` and `last_resort`.
5. Staff exception-review queue for `ProgramReferral`, with the "could not determine" reason.

Each slice is an eligibility or payment hard surface and gets a second-vendor review and a
native read before merge.

## Open questions
- Do any urban Indian organizations operate PRC? If one does, it uses `PrcReferral` as it is.
- Which payer-of-last-resort rules apply to a Title V program? Counsel.
- Does a Corvid tenant for a program that does not run RPMS need its own tenancy ADR? ADR 0007
  covers the EHR read, not tenancy.

## References
- #866, #605 (ADR 0007), ADR 0005
- `app/models/corvid/prc_referral.rb`, `app/models/corvid/alternate_resource_check.rb`,
  `app/services/corvid/alternate_resource_service.rb`, `lib/corvid/program_registry.rb`
