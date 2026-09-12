# CMS IPPS Data Ingestion

The PRC overpayment analyzer prices inpatient hospital obligations
against real CMS IPPS (Inpatient Prospective Payment System) Final
Rule rates loaded into `corvid_ipps_drg_weights` and
`corvid_ipps_hospital_rates`. This doc covers where the source data
comes from, how it's normalized into the canonical CSV shape, and
how to ingest a year.

## Coverage target

FY 2007 through FY 2026 (matches PFS coverage; supports querying all
PRC overpayments since July 2007).

## Source

CMS publishes annual **IPPS Final Rule** tables at:
https://www.cms.gov/medicare/payment/prospective-payment-systems/acute-inpatient-pps

For each fiscal year the relevant tables are:

| Table | Contents | Used for |
| --- | --- | --- |
| Table 5 | MS-DRG list, relative weights, mean LOS | `corvid_ipps_drg_weights` |
| Table 1A / 1B | National Adjusted Operating Standardized Amounts (labor + nonlabor) | `corvid_ipps_hospital_rates.base_rate` (NATIONAL row) |
| Wage Index PUF (Table 2 equivalent) | Occupational-mix-adjusted wage index by CBSA / rural-state area | `corvid_ipps_hospital_rates.wage_index` (per-locality rows — see "Per-CBSA wage index" below) |

CMS distributes these as ZIPs containing both `.txt` (tab-delimited)
and `.xlsx` versions. The `.txt` is easier to parse and matches the
`.xlsx` byte-for-byte after Excel formatting; we normalize from the
`.txt`.

## Canonical CSV shape

Two files per year, named:

```
ipps_drg_weights_FY{year}.csv
ipps_hospital_rates_FY{year}.csv
```

DRG weights:

```csv
# IPPS DRG relative weights, FY 2026
# release_label: cms_fy2026_final_rule
# source: CMS-1833-F Table 5 (FY 2026 IPPS Final Rule)
# weight column: Weights - 10% Cap Applied
drg_code,relative_weight,description
001,28.0239,"HEART TRANSPLANT OR IMPLANT OF HEART ASSIST SYSTEM WITH MCC"
...
```

Hospital rates:

```csv
# IPPS hospital base rates, FY 2026
# release_label: cms_fy2026_final_rule
# source: CMS-1833-F Table 1A/1B (FY 2026 IPPS Final Rule)
locality,base_rate,wage_index
NATIONAL,6752.61,1.0000
```

The leading `#`-comment lines are stripped by the importer; the first
header line is `release_label:` so the importer knows whether the
data is real-CMS or stub-derived. When `release_label` starts with
`stub`, the analyzer reports `:stub_estimate` confidence; otherwise
`:clear` / `:real`.

## Per-year normalization recipe

```bash
# 1. Find the year's Final Rule home page
open "https://www.cms.gov/medicare/payment/prospective-payment-systems/acute-inpatient-pps/fy-${YEAR}-ipps-final-rule-home-page"

# 2. Download Table 5 + Tables 1A-1E ZIPs

# 3. Extract the .txt files

# 4. Parse Table 5 into ipps_drg_weights_FY${YEAR}.csv
#    - Column 1 (MS-DRG, 3-digit code) → drg_code
#    - Column 8 (Weights - 10% Cap Applied; column 7 in older years) → relative_weight
#    - Column 6 (MS-DRG Title) → description

# 5. Parse Table 1A into ipps_hospital_rates_FY${YEAR}.csv
#    - NATIONAL row: base_rate = labor + nonlabor for the
#      Hospital-Submitted-Quality + Meaningful-EHR-User column
#    - wage_index = 1.0 for the NATIONAL fallback

# 6. Hand-vet a few values against the published Final Rule preamble
#    (e.g., the "operating standardized amount" sentence in section II
#    typically quotes the labor+nonlabor sum directly).

# 7. Upload to the cms-fee-schedules-v1 release
gh release upload cms-fee-schedules-v1 \
  ipps_drg_weights_FY${YEAR}.csv \
  ipps_hospital_rates_FY${YEAR}.csv \
  --repo lakeraven/corvid --clobber

# 8. Fetch + import in the host app
rake cms:ipps:fetch_release[${YEAR}]
```

## Layout drift across years

CMS shifts column layouts roughly every 3–5 years and renames tables.
Things to watch for in older files:

- Pre-FY 2008: MS-DRG system didn't exist (CMS-DRG was used 1983–2007).
  CMS published the MS-DRG conversion in FY 2008. PRC obligations
  with service dates before FY 2008 may need DRG remapping or
  fall back to a CMS-DRG provider (out of scope for #276).
- FY 2008–2014: column for "Weights - 10% Cap Applied" didn't exist;
  use the single weight column instead.
- FY 2024 onwards: "Hospital Did NOT Submit Quality Data" columns
  were re-numbered. Always anchor on the column header text, not
  position.

## Production ingest priority

By dollar volume in tribal PRC obligations:

1. FY 2026 — most recent claims; loaded today.
2. FY 2025–2023 — recent recoverable years.
3. FY 2022–2018 — older recoverable; statute of limitations varies.
4. FY 2017–2007 — long-tail; stub_estimate is acceptable until
   real demand work needs them.

## Coverage status

**19 of 20 fiscal years on real CMS Final Rule data** (FY 2008–2026
contiguous). FY 2007 remains on stub fallback — see "Remaining gap"
below.

| FY | Status | release_label |
| --- | --- | --- |
| 2026 | Real CMS data | `cms_fy2026_final_rule` |
| 2025 | Real CMS data | `cms_fy2025_final_rule` |
| 2024 | Real CMS data | `cms_fy2024_final_rule` |
| 2023 | Real CMS data | `cms_fy2023_final_rule` |
| 2022 | Real CMS data | `cms_fy2022_final_rule` |
| 2021 | Real CMS data | `cms_fy2021_final_rule` |
| 2020 | Real CMS data | `cms_fy2020_final_rule` |
| 2019 | Real CMS data | `cms_fy2019_final_rule` |
| 2018 | Real CMS data | `cms_fy2018_final_rule` |
| 2017 | Real CMS data | `cms_fy2017_final_rule` |
| 2016 | Real CMS data | `cms_fy2016_final_rule` |
| 2015 | Real CMS data | `cms_fy2015_final_rule` |
| 2014 | Real CMS data | `cms_fy2014_final_rule` |
| 2013 | Real CMS data | `cms_fy2013_final_rule` |
| 2012 | Real CMS data | `cms_fy2012_final_rule` |
| 2011 | Real CMS data | `cms_fy2011_final_rule` |
| 2010 | Real CMS data | `cms_fy2010_final_rule` |
| 2009 | Real CMS data (Table 5 parsed from .xls; T1A from .txt) | `cms_fy2009_final_rule` |
| 2008 | Real CMS data | `cms_fy2008_final_rule` |
| 2007 | Stub fallback — see #308 | — |

## Remaining gap: FY 2007 only

CMS published the FY 2007 IPPS Final Rule under the **CMS-DRG** code
system (the previous version of the DRG taxonomy; MS-DRG didn't take
effect until FY 2008). Table 5 for FY 2007 is available as a download
(`table5_fn07_sept.zip` on cms.gov), but Table 1 (national operating
standardized amounts) wasn't published as a standalone file for that
year — the rate appeared in the Federal Register narrative text only.

Tracked in **#308**. Practical paths to backfill:

1. **Federal Register PDF** — extract the operating standardized
   amount sentence from the rule preamble (typically section II of
   the Final Rule). Manual one-time exercise.
2. **Skip FY 2007** — for tribal PRC recovery, FY 2007 obligations
   are 19+ years old; statute of limitations and write-offs typically
   eliminate recovery options. The in-code stub continues as
   fallback at `:stub_estimate` confidence.

Note: even with FY 2007 Table 1, the FY 2007 DRG codes are CMS-DRG
not MS-DRG. The PrcProcedureDictionary maps procedure descriptions
to MS-DRG codes; routing FY 2007 obligations through the analyzer
would also need a CMS-DRG → MS-DRG crosswalk (CMS published one
during the FY 2008 transition).

## Per-CBSA wage index (#369, parent #351)

Every `corvid_ipps_hospital_rates` row shipped so far has been
`locality: "NATIONAL"` with `wage_index: 1.0` — real DRG weight and
base-rate data, but no geographic wage adjustment. CMS's real IPPS
(and OPPS/ASC — they share the same wage-area data) payment varies
the operating standardized amount by CBSA wage index, often by
±30–40% relative to the national average. `IppsHospitalRate` and its
`.lookup(fiscal_year:, locality:)` method already supported
per-locality rows (CBSA-or-NATIONAL fallback) — only the *data* was
missing.

`Corvid::CmsIppsWageIndexNormalizer` (added in this PR) reads CMS's
annual **Wage Index Public Use File**
(`fy{YEAR}-ipps-fr-wage-index-puf.zip`, linked from the Final Rule
home page's "Wage Index" section) and produces the same canonical
`ipps_hospital_rates_FY{year}.csv` shape the existing
`cms:ipps:import_hospital_rates` / `cms:ipps:fetch_release` tasks
already consume — no new importer needed. Use it via:

```bash
rake "cms:ipps:normalize_wage_index[2026,/tmp/wage_index_2026/3.\ FY26...cbsaoccmix_nooccmix.txt,/tmp/ipps_hospital_rates_FY2026.csv,6752.61,cms_fy2026_final_rule]"
rake cms:ipps:import_hospital_rates[2026,/tmp/ipps_hospital_rates_FY2026.csv,cms_fy2026_final_rule]
```

The wage index figure used is the **occupational-mix-adjusted**
value (CMS's Table 2 equivalent) — pre-reclassification,
pre-rural-floor, pre-out-migration-adjustment, pre-budget-neutrality.
Same "screening estimate, not adjudication" posture the analyzer
already documents for IME/DSH/outlier (#320/#321): materially more
accurate than a flat 1.0, not a byte-for-byte reproduction of a
specific hospital's actual payable wage index.

Validated end-to-end against the real FY2026 CMS file (465 CBSA/
rural-state rows): Billings, MT (CBSA 13740) carries a 0.8961 wage
index — an OPPS APC 5071 screening rate of $2,083.79 vs. $2,325.40 at
the flat NATIONAL default, a ~10% difference that matters for tribal
PRC recovery-triage accuracy in low-wage-index rural areas.

**Data loaded in the shared `cms-fee-schedules-v1` GitHub Release:**
FY 2026 only (as of this PR — a maintainer with release-upload access
should run the recipe above for additional fiscal years and re-run
`gh release upload`). `OppsRateProvider` and `AscRateProvider` now
source wage index from this table (#369); until the analyzer itself
passes a real CBSA locality (blocked on #372's zip→CBSA resolution),
production OPPS/ASC pricing still resolves to the IPPS NATIONAL row
(wage_index 1.0) in practice — this PR lands the plumbing and the
per-CBSA data table, not the last-mile wiring from facility ZIP to
CBSA code.

Remaining in this cluster:
- **#370** — drop the now-unused `wage_index` column from
  `corvid_opps_conversion_factors` / `corvid_asc_conversion_factors`
  (kept in this PR to avoid a data-loss migration before #369 is
  proven in production).
- **#372** — resolve `facility.locality` to a real CBSA code from the
  facility ZIP so the per-CBSA wage index in this table actually
  changes OPPS/ASC pricing on production obligations, not just in
  direct rate-provider calls.
