# CMS ASC Data Ingestion

The PRC overpayment analyzer routes outpatient (APC-mapped) claims to
**ASC pricing** when the obligation's vendor is on the CMS Ambulatory
Surgical Center registry on the service date.

ASC has its own data shape — distinct from OPPS:

- **Facility registry**: which CCNs are ASCs (sourced from CMS iQIES POS).
- **HCPCS rates**: ASC publishes payment per HCPCS (NOT per APC; different from OPPS Addendum A).
- **Conversion factor**: separate from OPPS — typically ~60% of OPPS CF.

## Coverage status

| CY | Facilities | HCPCS rates | CF | Status |
|---|---:|---:|---:|---|
| 2026 Q1 | 8,355 (6,593 active) | 3,924 | $56.322 | **Real CMS data** |
| 2025 | — | — | $54.895 (known) | Pending |

End-to-end pricing example: HCPCS 0102T at CY 2026 NATIONAL prices
to `29.2047 × 56.3220 × 1.0 = $1,644.87` — matches the published
Addendum AA Payment Rate exactly.

## Facility registry — CMS iQIES POS

The authoritative source for the ASC facility list is the **CMS iQIES
Provider of Services file** (HHA / ASC / Hospice — different from the
Hospital POS used for CAH). Published quarterly at data.cms.gov,
~175 MB CSV covering ~77K facilities; filter to ASCs
(`prvdr_type_id = '11'`).

iQIES vs Hospital POS conventions:
- Lowercase column names (`prvdr_num` vs `PRVDR_NUM`)
- Dates already YYYY-MM-DD (vs YYYYMMDD)
- Termination encoded via `trmntn_exprtn_dt = "Not Available"` sentinel
- No separate `pgm_trmntn_cd` column

ASC CCNs use letter-prefix format (`17C0001897`) rather than the
6-digit numeric format Hospital CAH uses.

### Facility recipe

```bash
# 1. Latest iQIES POS URL via data.cms.gov catalog
curl -sL https://data.cms.gov/data.json \
  | jq -r '.dataset[] | select(.title | test("Provider of Services.*iQIES|Internet Quality")) | .distribution[].downloadURL' \
  | grep -iE "POS_File_iQIES_Q.*\.csv|ProviderOfService_iQIES_" | head -1

# 2. Download (~175 MB)
curl -sL "${POS_URL}" -o /tmp/cms_pos_iqies.csv

# 3. Normalize → canonical CSV
bundle exec rails "cms:asc:normalize_pos[/tmp/cms_pos_iqies.csv,/tmp/asc_facilities_${QUARTER}.csv,cms_iqies_${QUARTER}]"

# 4. Upload + import
gh release upload cms-fee-schedules-v1 /tmp/asc_facilities_${QUARTER}.csv --repo lakeraven/corvid --clobber
bundle exec rails "cms:asc:import_facilities[/tmp/asc_facilities_${QUARTER}.csv,cms_iqies_${QUARTER}]"
```

## HCPCS rates — CMS ASC Addendum AA

Source: the **ASC Addenda** zip shipped alongside each OPPS Final Rule
(same CMS-NNNN-FC rule page as OPPS Addendum A). The zip contains
six addenda (AA, BB, DD1, DD2, EE, FF); we normalize **Addendum AA**
("ASC Covered Surgical Procedures for CY {year}").

Zip name pattern: `january_{year}_asc_addenda.MM.DD.YYYY.zip`.

ASC publishes rates **per HCPCS**, not per APC. Our `AscHcpcsRate`
model keys by `(calendar_year, hcpcs_code)` and stores the `payment_indicator`
(G2, J8, R2, P2, etc.) alongside the `payment_weight`.

### Canonical CSV shape

```csv
# release_label: cms_asc_cy2026_final_rule
hcpcs_code,payment_indicator,payment_weight
0101T,R2,2.4065
0102T,G2,29.2047
0200T,J8,83.7955
```

### Per-year recipe

```bash
# 1. Download the year's ASC Addenda zip from CMS-NNNN-FC rule page
# 2. Extract to /tmp/asc_${YEAR}_addenda/

# 3. Normalize Addendum AA (CSV lives in the 508 Version subdirectory)
bundle exec rails "cms:asc:normalize_addendum_aa[${YEAR},/tmp/asc_${YEAR}_addenda/508 Version*/Addendum AA*.csv,/tmp/asc_hcpcs_rates_CY${YEAR}.csv,cms_asc_cy${YEAR}_final_rule]"

# 4. Hand-write the conversion factor CSV (single number per year)
cat > /tmp/asc_conversion_factors_CY${YEAR}.csv <<CSV
# release_label: cms_asc_cy${YEAR}_final_rule
locality,conversion_factor,wage_index
NATIONAL,${ASC_CF},1.0000
CSV

# 5. Upload both to the cms-fee-schedules-v1 release
gh release upload cms-fee-schedules-v1 \
  /tmp/asc_hcpcs_rates_CY${YEAR}.csv \
  /tmp/asc_conversion_factors_CY${YEAR}.csv \
  --repo lakeraven/corvid --clobber

# 6. Import
rake cms:asc:import_hcpcs_rates[${YEAR},/tmp/asc_hcpcs_rates_CY${YEAR}.csv,cms_asc_cy${YEAR}_final_rule]
rake cms:asc:import_conversion_factors[${YEAR},/tmp/asc_conversion_factors_CY${YEAR}.csv,cms_asc_cy${YEAR}_final_rule]
```

### Known conversion factors

| CY | ASC CF | Source |
|---|---:|---|
| 2026 | $56.322 | CMS-1834-FC |
| 2025 | $54.895 | CMS-1809-FC |

For ASCs subject to a quality-reporting reduction, the CF is slightly
lower (CY 2026: $55.224 vs $56.322). We ship the standard OQR-compliant
CF in the canonical CSV; per-ASC reduction handling is a future
enhancement tracked under deferred adjudication adjustments (#321).

## Note on Payment Indicator

`payment_indicator` (e.g., G2, J8, R2, P2) is stored alongside each
HCPCS rate but the analyzer's screening-estimate path doesn't yet
branch on it. Future per-PI pricing logic (office-based at PFS,
device-intensive offsets, etc.) is part of #321.

## Note on APC mismatch (architectural)

Earlier versions of the ASC pricing path mirrored OPPS structurally —
APC-keyed weights via `AscApcWeight`. That was wrong: CMS publishes
ASC rates per HCPCS, not per APC. The current `AscHcpcsRate` model
corrects this; `analyze_outpatient` passes `proc_info.hcpcs` (not
`proc_info.apc`) to `AscRateProvider.lookup_for`.
