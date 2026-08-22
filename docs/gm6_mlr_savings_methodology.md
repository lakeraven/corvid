# GM-6 · MLR repricing savings demo — methodology

Runbook + methodology for corvid#469 (**hard deadline Aug 28 2026**), the
companion to the GM-5 PRC eligibility demo (corvid#468).

## What this demo proves

That Corvid's real Medicare-Like Rate (MLR) repricing engine — the same
`Corvid::PrcReportParser` → `Corvid::PrcOverpaymentAnalyzer` pipeline
production PRC imports run through — reprices a representative purchased/
referred-care (PRC) claim panel for a 2-provider Urban Indian Organization
(UIO) street-medicine clinic and produces one defensible headline number.

**Reproduce:**

```bash
cd corvid
bundle install                                                      # first time
cd test/dummy && RAILS_ENV=test bin/rails db:prepare && cd ../..    # first time
cd test/dummy && RAILS_ENV=test bin/rails demo:mlr_savings
```

The task is idempotent — every seeded rate row and the whole claim panel are
deleted/recreated on each run, so it's safe to re-run.

## Headline number (this branch, this run)

```
Claims analyzed:                300
Total billed (=paid):           $126,240.90
Total Medicare-Like Rate (MLR): $51,304.23
TOTAL ANNUAL PRC SAVINGS:       $74,936.67  (~59.4%)
```

*"We cut your PRC cost by $74,936.67 — about 59% — on this panel, just by
repricing every purchased-care claim to Medicare-Like Rates."*

All 300 claims resolve at `recovery_confidence: :clear` / `rate_source: :real`
— every dollar in both totals is priced off real CMS rate data (see below),
none of it is stub/estimated.

## Real vs. representative — the honest accounting

**Real** (actual CMS CY2026/FY2026 published rates, run through the real
`PfsRateProvider`-equivalent (`FeeScheduleEntry#medicare_rate`),
`IppsRateProvider`, and `OppsRateProvider`):

| System | Rate basis | Source |
|---|---|---|
| PFS (professional) | work/PE/MP RVU × Montana (locality 01) GPCI × CY2026 conversion factor $33.4009 | CMS CY2026 PFS Final Rule (CMS-1832-F), `PPRRVU2026_Jan_nonQPP.csv` + `GPCI2026.csv` from `RVU26A.zip` (the same zip `rake cms:fetch[2026]` downloads) |
| IPPS (inpatient) | DRG relative weight × $6,752.61 national base rate × wage index 1.0 | CMS FY2026 IPPS Final Rule (CMS-1833-F), `ipps_drg_weights_FY2026.csv` / `ipps_hospital_rates_FY2026.csv` (pulled live via `rake cms:ipps:fetch_release[2026]` and independently cross-checked against CMS's published FY2026 payment brief) |
| OPPS (hospital outpatient) | APC relative weight × $91.4150 national conversion factor × wage index 1.0 | CMS CY2026 OPPS Final Rule (CMS-1834-FC), `opps_apc_weights_CY2026.csv` / `opps_conversion_factors_CY2026.csv` (pulled live via `rake cms:opps:fetch_release[2026]`, cross-checked against CMS's CY2026 OPPS fact sheet) |

Wage index is 1.0 (NATIONAL) for IPPS/OPPS rather than Billings, MT's real
per-CBSA wage index (0.8961, CBSA 13740, validated in PR #467) — production
doesn't yet resolve a facility ZIP to a CBSA row (tracked separately as
#372), so this demo matches current production behavior instead of
hand-wiring a shortcut around it. Because Billings' real wage index is
**below** 1.0, the true CBSA-adjusted MLR would be **lower**, and the
savings number **higher** — this demo undersells the number it could show
once #372 lands, not the other way around.

**Representative / synthetic** (clearly bounded to this one input):

- The claim **panel itself** — patient count, referral rate, procedure-code
  mix, and service dates. No PHI; see "Claim panel assumptions" below.
- **Billed charges.** No real vendor invoice exists for this demo, so
  billed = MLR × a multiplier (PFS 1.8×, OPPS 3.0×, IPPS 3.5×), loosely
  consistent with published charge-to-Medicare benchmarks (professional
  charges commonly run ~150–250% of Medicare; hospital facility charges
  run substantially higher). **Paid = billed** — this panel models a
  clinic paying full provider billed charges today, i.e. no MLR repricing
  in place yet, which is the correct pre-MLR baseline for a "here's what
  repricing recovers" pitch and is exactly the failure mode 42 CFR 136.30
  (and this whole product) exists to catch.

Nothing about the *rate side* of the number is invented. The only
lever that could move the headline number is the billed-charge multiplier
assumption — change `BILLED_MULTIPLIER` in
`lib/tasks/demo_mlr_savings.rake` and re-run to see the effect.

## Claim panel assumptions

- **Panel size:** 1,200 active patients (600/provider) for a 2-provider UIO
  street-medicine clinic — below the standard 1,500–2,500 primary-care
  panel, reflecting higher case complexity in a street-medicine population.
- **Referral rate:** ~20% of the panel (240 patients) has at least one
  purchased/referred-care episode in the modeled year.
- **Claim volume:** 300 total obligations (~1.25 claims per referred
  patient) — 270 professional (PFS), 28 hospital-outpatient ED visits
  (OPPS), 2 inpatient hospitalizations (IPPS). Inpatient stays are
  deliberately rare (rare, catastrophic-cost events for a panel this size)
  and deliberately few — corvid#469 asked for "maybe 1-2 inpatient stays";
  this panel has exactly 2, so every inpatient dollar traces to a named
  example claim rather than a distribution.
- **Why the total looks modest ($126K billed, not $1M+):** small UIO PRC
  programs are chronically underfunded and typically authorize only a
  fraction of clinically indicated referrals (often just Priority I /
  emergent cases). A constrained referral budget is the realistic
  baseline for this kind of clinic, not an artifact of under-modeling —
  and it's the sharper story for the demo: **even on a modest,
  cash-strapped referral budget, MLR repricing recovers real money the
  program can put back into authorizing more care.** Scale every count in
  `PFS_MIX` / `OPPS_MIX` / `IPPS_MIX` uniformly to size this to a specific
  program's real referral volume.

## Example claims (full math)

```
GM6-0071  [pfs]  Office/outpatient visit, established patient, low complexity
  billed=$171.34  paid=$171.34  MLR=$95.19  savings=$76.15
  (1.30 work + 1.46 PE + 0.09×0.998 MP) × $33.4009 = $95.19; billed = MLR × 1.8

GM6-0281  [opps]  Hospital outpatient ED visit, level 3 (moderate)
  billed=$836.67  paid=$836.67  MLR=$278.89  savings=$557.78
  APC 5023 weight 3.0508 × $91.4150 CF × 1.0 wage index = $278.89; billed = MLR × 3.0

GM6-0299  [ipps]  Septicemia or severe sepsis w/o MV 96+ hours w/o MCC
  billed=$24,184.83  paid=$24,184.83  MLR=$6,909.95  savings=$17,274.88
  DRG 872 weight 1.0233 × $6,752.61 base rate × 1.0 wage index = $6,909.95; billed = MLR × 3.5
```

## Breakdown by payment system (this run)

```
PFS    n=270  billed=$51,100.40   mlr=$28,389.20   savings=$22,711.20
OPPS   n= 28  billed=$30,372.69   mlr=$10,124.23   savings=$20,248.46
IPPS   n=  2  billed=$44,767.81   mlr=$12,790.80   savings=$31,977.01
```

Two inpatient stays account for more than a third of the year's total
savings — consistent with how MLR repricing overwhelmingly matters for
high-dollar hospital claims, even though they're a small share of claim
*count*.

## Known bugs found while building this (filed as follow-ups, not fixed here)

Building this task surfaced two real defects in `Corvid::CmsFeeScheduleParser`
on the CY2026+ PPRRVU file layout — the reason the PFS rates above are
hand-verified literals rather than pulled through `rake cms:import[2026]`:

1. **`parse_gpcis` locality-key collision.** GPCI rows are keyed only by
   the 2-digit locality code, which is not nationally unique — many MACs
   reuse the same locality number for different states (Montana's `01` is
   one of several). The importer's last-row-wins behavior means a bulk
   `cms:import[2026]` run silently loads the wrong state's GPCI for any
   locality number used by more than one MAC.
2. **`mp_col` header-detection fallback breaks on the CY2026 layout.**
   CY2026's `PPRRVU2026_Jan_nonQPP.csv` has two PE RVU columns
   (non-facility, facility) where older years had one; the parser's
   fallback offset (`work_col + 9`) no longer lands on the MP RVU column —
   it lands on GLOB DAYS instead. Confirmed: a `cms:import[2026]` run
   loads `mp_rvu: 0.0` for CPT 99213, vs. the correct `0.09` read directly
   off the CMS file.

A third, smaller issue — `rake cms:ipps:fetch_release[year]`'s summary
`puts` referenced an undefined `label` variable (`NameError` after the
data import itself had already succeeded) — **is fixed in this branch**
(`lib/tasks/cms_ipps.rake`), since it directly blocked this demo task
from using the production fetch path for IPPS.

See the PR description for the filed follow-up issue covering (1) and (2).
