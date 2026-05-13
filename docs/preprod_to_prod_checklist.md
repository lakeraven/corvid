# Pre-Production to Production Checklist

Companion to `docs/release_readiness.md` (#355). That doc covers the broader screening-grade vs adjudication-grade distinction. This doc covers the narrower transition gate: **what we tolerate in pre-prod that must be fixed before the first production-like deployment.**

## Status legend

- ✅ Already fixed / not applicable
- 🟡 Acceptable pre-prod, must fix before prod
- ⛔ Must fix immediately regardless of prod status

## Tolerate now (pre-production)

| Item | Status | Notes |
|---|---|---|
| Edit existing migrations in place (instead of forward migrations) | 🟡 | Acceptable while all envs are disposable. Each dev/CI must `db:drop db:create db:migrate` after pulling. No production history exists to preserve. |
| Schema-reset requirement after pulling a branch that edited an old migration | 🟡 | Document in PR descriptions when an in-place migration edit is part of the change. |
| Limited per-Payment-Indicator (PI) logic in ASC pricing | 🟡 | ASC currently prices by `payment_weight × CF × wage_index` regardless of PI (G2 vs P2 vs R2 etc.). Sufficient for screening; full per-PI behavior tracked in #321. |
| Manual ops runbook steps for CMS data refresh | 🟡 | `docs/cms_*_data.md` lists the operator commands per data family. Acceptable while deterministic and documented. |
| NATIONAL-only wage index for OPPS + ASC | 🟡 | Per-CBSA wage tracked in #351. Typical rural-tribal impact <5%. |
| Admin-merge via `gh pr merge --admin` while branch protection requires up-to-date branch | 🟡 | Current cadence: rebase + admin-merge per pre-prod stance. Before cutover, switch to plain `gh pr merge` and remove the `--admin` privilege from the workflow. |

## Must fix before first production deployment

| Item | Status | Evidence / Issue |
|---|---|---|
| Strict numeric parsing on every rate-data ingest path (no silent `to_f` → 0.0) | ✅ | Rate parsers raise `MalformedFileError` with row context on garbage: OPPS via `CmsOppsParser` (#310), IPPS via `CmsIppsParser` (#276), ASC via `CmsAscParser` (#347). |
| Facility-list ingest surfaces bad rows instead of silently dropping them | ✅ | `CmsFacilityListParser` + `CmsPosCahNormalizer` + `CmsPosAscNormalizer` use a `{rows:, rejects: [{ccn:, reason:}]}` shape — bad rows go to `rejects` with row context, good rows survive. Per-row reject (skip + report), not raise. Documented in `docs/cms_cah_data.md` and `docs/cms_asc_data.md`. |
| Per-payment-system parser unit tests pin failure modes | 🟡 | OPPS + ASC parsers covered (`cms_opps_parser_test.rb`, `cms_asc_parser_test.rb`). Add rake-task-level integration tests that load real-shape CSVs with deliberately-malformed numeric values and assert non-zero exit. |
| Frozen migration history before cutover | 🟡 | Pre-prod policy is edit-in-place; **at the prod-cutover gate, freeze the migration set as-is and require forward migrations from then on.** Tag the commit at cutover as `prod-cutover-v1`. |
| Operational guardrails on rake imports | 🟡 | Today rake tasks `puts` row counts + reject reasons. Add: expected-count assertions per snapshot label (e.g., "CY 2026 OPPS APC weights should be 245–260 rows; alert on deviation"), and non-zero reject counts should fail (not just log). |
| Release-label audit per ingested dataset | ✅ | Every analysis row carries `rate_source_release`; methodology.json carries the full set per packet. (#317) |
| Recoverable-rule gates every dollar-emitting surface | ✅ | RecoverableRule + scope + predicate enforced across CSV, JSON, audit packet, demand letter. (#311–#316, multi-label contract #313) |
| End-to-end byte-stability of audit-packet artifacts | ✅ | Deterministic ordering throughout reports; same-snapshot exports are byte-equal. (#314, #315) |
| Trailer integrity check on PRC import | ✅ | `trailer_check: :ok / :mismatched / :missing` (#324) |

## Decision points (must answer before cutover)

These aren't bugs — they're choices that need to land before production behavior is set:

| Question | Default | Decision needed |
|---|---|---|
| When a vendor's NPI doesn't match any CCN in the registry, do we attempt NPPES crosswalk on the fly, or require pre-import? | Pre-import (operator pre-maps NPI→CCN) | Requires NPI crosswalk infrastructure (#353) |
| 340B-recouped CF variant — apply to specific vendors or ignore? | Ignore (use full-update CF) | Tracked under #321 adjudication adjustments |
| FY 2007 IPPS — block claims with that service date, fall back to stub, or hand-load via Federal Register? | Currently falls back to stub | #322 |
| ASC PI-specific pricing (office-based at PFS, device-intensive offsets) | Currently flat weight × CF | #321 |
| Mid-year CF changes (CY 2010 OPPS) | First-half value stored as annual | #352 — small dollar impact |

## Operational gates for cutover

Before the first production-like deployment, this list must be true:

- [ ] All "Must fix" items above show ✅
- [ ] Migration set frozen + tagged
- [ ] `docs/release_readiness.md` (#355) checklist completed
- [ ] At least one full PRC export from a real customer environment processed end-to-end with byte-equal repeat runs
- [ ] Real CMS data loaded for every payment system we route to (PFS, IPPS, OPPS, ASC, CAH registry)
- [ ] Audit packet methodology.json reviewed by counsel or compliance for tribal/HIPAA accuracy
- [ ] Recovery-letter language reviewed and approved
- [ ] Backup + DR procedures documented
- [ ] Customer-visible error surfaces documented (what an operator sees when an import fails)

## Related

- #355 — Release-readiness checklist (screening-grade vs adjudication-grade)
- #320 / #321 — Deferred adjudication adjustments
- #322 — FY 2007 IPPS gap
- #348 — Single canonical pricing path
- #349 / #350 — Dedicated rate-provider + importer regression tests
- #351 — Per-CBSA wage index
- #352 — Mid-year CF support
- #353 — NPI↔CCN crosswalk
- #354 — Format-matrix fixtures in CI
