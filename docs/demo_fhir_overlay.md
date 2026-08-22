# Corvid overlay via stock FHIR — multi-clinic PRC + MLR demo

`rake demo:overlay` shows Corvid acting as a **read-only PRC + MLR overlay** on
top of a consortium of clinics that each run a **different source EHR**. Every
clinic is ingested over **stock FHIR R4** — no vendor-specific code — and Corvid
reprices each purchased/referred-care (PRC) charge to its **Medicare-Like Rate
(MLR)** under 42 CFR 136.30, reporting per-clinic and consortium dollars
recovered.

```
bundle exec rails demo:overlay        # seed synthetic FHIR -> ingest -> PRC/MLR -> report
bundle exec rails demo:overlay_reset  # delete ingested cases/obligations for both tenants
```

(run from `test/dummy`, or wherever the engine's rake tasks are mounted.)

## What it demonstrates

Two **synthetic** clinics — **Broken Rock Clinic** and **Tallgrass Clinic** —
form a consortium. Each is a self-contained FHIR R4 dataset (`Patient`,
`Coverage`, `Claim`) standing in for a PRC program on a different ambulatory
EHR. The clinics are invented; so are the patients, vendors, and dollar amounts.

1. **Stock-FHIR ingest.** Each clinic is read through the generic
   `Corvid::Adapters::FhirAdapter` (`find_patient`, `list_claims`). A thin,
   EHR-agnostic mapper (`Corvid::Demo::FhirOverlayIngest`) turns each FHIR
   `Patient` into a `Corvid::Case` (tokenized `patient_identifier`, no PHI at
   rest per ADR 0003) and each FHIR `Claim.item` into a `Corvid::PrcObligation`
   (billed CPT/HCPCS, service date, billed amount). No per-vendor branches.
2. **PRC eligibility.** The existing `EligibilityChecklistService` auto-populates
   from the same stock-FHIR adapter — tribal enrollment (a Lakeraven FHIR
   extension, since FHIR/US Core has no native tribal-enrollment concept),
   identity, and residency.
3. **MLR repricing.** The **unchanged** `Corvid::PrcOverpaymentAnalyzer`
   (the production pipeline, same one used by `demo:mlr_savings` / corvid#472)
   prices every obligation against real CMS CY2026 rates — PFS (Montana
   locality 01) and OPPS (national) — and reports `billed -> MLR -> recovered`
   per clinic and a **consortium total**.

## CEHRT-safe

Corvid never becomes the system of record. It reads the certified EHR over stock
FHIR and overlays PRC/MLR on top — read-only, no write-back. Because ingest is
generic FHIR R4, the **same code path works for any FHIR R4 EHR** in a
consortium, regardless of vendor. Vendor names appear in this demo only as a
neutral *source-EHR-type label in a comment*; the ingest touches no
vendor-specific field.

## What is real vs. synthetic (honesty)

- **Real:** the MLR side. PFS and OPPS rates are the same hand-verified CMS
  CY2026 Final Rule figures used by corvid#472 (see
  `docs/gm6_mlr_savings_methodology.md`), seeded with real CMS release labels,
  so the analyzer returns `rate_source: :real` / `recovery_confidence: :clear`.
- **Synthetic:** the clinics, patients, vendors, and **billed charges**. No real
  vendor invoice exists, so the billed amounts are invented (roughly 2–3× the
  Medicare rate). The **% recovered is therefore a modeled rate**, not one
  measured from real charges. The dollar *methodology* is real; the inputs are
  illustrative.

## Files

- `lib/corvid/demo/fhir_overlay_data.rb` — synthetic FHIR R4 datasets (2 clinics).
- `lib/corvid/adapters/fhir_demo_adapter.rb` — in-memory stock-FHIR server; the
  real `FhirAdapter` with only its HTTP transport overridden.
- `lib/corvid/adapters/fhir_adapter.rb` — generic `list_claims` stock-FHIR reader.
- `lib/corvid/demo/fhir_overlay_ingest.rb` — EHR-agnostic FHIR → Case/obligation mapper.
- `lib/corvid/demo/cms_rate_seed.rb` — real CMS rate seeding + PRC dictionaries.
- `lib/corvid/demo/fhir_overlay_demo.rb` — orchestration + report.
- `lib/tasks/demo_fhir_overlay.rake` — `demo:overlay`, `demo:overlay_reset`.
- `test/lib/corvid/demo/fhir_overlay_test.rb` — end-to-end coverage.
