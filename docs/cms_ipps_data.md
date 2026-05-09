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
| Table 4A / 4B | Wage indexes by CBSA / state | `corvid_ipps_hospital_rates.wage_index` (per-locality rows; future) |

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

| FY | Status | release_label |
| --- | --- | --- |
| 2026 | Real CMS data | `cms_fy2026_final_rule` |
| 2007–2025 | Stub fallback (in-code provider) | — |
