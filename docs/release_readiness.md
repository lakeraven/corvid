# Release Readiness: PRC MLR Recovery

This checklist defines the bar for presenting PRC Medicare-Like Rate
results. Corvid currently targets **screening-grade** recovery analysis:
defensible for triage, council reporting, audit packets, and demand-letter
workflows when recoverable-rule gates are applied. It is not yet
adjudication-grade claim pricing.

## Status legend

- Pass — implemented and covered by code or tests.
- Partial — acceptable for pre-production, but must be closed or explicitly
  accepted before a production-like deployment.
- Fail — not implemented.

## Screening-grade criteria

| Criterion | Status | Evidence |
|---|---|---|
| Real CMS PFS data available for professional services | Pass | `cms:snapshot:load` loads the bundled PFS snapshot; `FeeScheduleEntry.rate_for` is used by `PrcOverpaymentAnalyzer`. |
| Real CMS IPPS data path for inpatient hospital claims | Partial | `IppsRateProvider` uses loaded Final Rule rows and falls back to stubs when missing; FY 2007 remains tracked by #322. |
| Real CMS OPPS data path for outpatient hospital claims | Pass | `OppsRateProvider` and CY 2007-2026 OPPS backfill are in place. |
| ASC routing and rate path | Partial | ASC facility registry, HCPCS rates, and CF path exist; full payment-indicator behavior remains under #321. |
| CAH routing and 101% multiplier | Pass | `CahFacility.applies?` plus analyzer-boundary 1.01x adjustment. |
| NPI-keyed vendor matching for CAH/ASC | Pass | `NpiCcnCrosswalk` supports per-release snapshots and CAH/ASC lookup resolves NPI-keyed vendors through CCNs. |
| Recoverable-rule gates every dollar-emitting surface | Pass | `RecoverableRule` gates CSV/JSON/audit packet/demand-letter paths. |
| Stub-derived dollars excluded from council-facing recoverable totals | Pass | `PrcOverpaymentAnalyzer::Summary` separates clear from stub-estimate totals; demand letters reject non-recoverable analyses. |
| Provenance threaded end to end | Pass | `rate_source_release` is carried from rate rows into analysis rows and methodology artifacts. |
| PRC import trailer integrity is tracked | Pass | Import stores `trailer_check` state for ok/mismatched/missing trailers. |
| Missing service dates are isolated from rate-data gaps | Pass | Analyzer emits `:missing_service_date` rather than `:no_rate_for_year`. |
| PRC export fixture variants enforced by CI | Fail | Format-matrix fixtures exist, but CI contract tests are tracked by #354. |
| Single canonical pricing path | Pass | `PrcOverpaymentAnalyzer` is canonical; the old `RepricingService`/`OverpaymentRecovery::AuditService` path has been retired. |

## Adjudication-grade additions

| Criterion | Status | Issue |
|---|---|---|
| IPPS IME, DSH, capital, outlier, and transfer adjustments | Fail | #320 |
| OPPS packaging, copay, outlier, pass-through, and 340B variants | Fail | #321 |
| ASC payment-indicator-specific behavior | Partial | #321 |
| OPPS and ASC per-CBSA wage indexes | Fail | #351 |
| Mid-year conversion-factor changes | Fail | #352 |
| FY 2007 IPPS CMS-DRG to MS-DRG handling | Fail | #322 |
| CLFS and DMEPOS long-tail coverage | Fail | #280 |

## Operational gates

Before the first production-like deployment:

- All screening-grade criteria must be Pass, or a named decision must accept
  the residual risk.
- The companion [pre-production checklist](preprod_to_prod_checklist.md) must
  show no open Must Fix items.
- At least one real customer PRC export must process end to end twice with
  byte-stable report and audit-packet artifacts.
- Counsel or compliance must review `methodology.json` and demand-letter
  language for tribal, HIPAA, and recovery accuracy.
- Operator-facing CMS data refresh failures must be documented, including row
  count expectations and reject handling.
- Migration history must be frozen and tagged at the production cutover commit.

## Customer-facing language

Use "screening-grade Medicare-Like Rate recovery analysis" unless every
adjudication-grade criterion above is Pass. Demand letters and reports must
cite source/confidence labels and must not present stub-derived estimates as
recoverable dollars.
