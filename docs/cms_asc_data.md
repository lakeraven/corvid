# CMS ASC Registry Ingestion

The PRC overpayment analyzer routes outpatient (APC-mapped) claims to
**ASC pricing** (lower CF than OPPS) when the obligation's vendor is
on the CMS Ambulatory Surgical Center registry on the service date.

This doc covers the ASC **facility registry** sourcing. The ASC
HCPCS weight + conversion factor data is a separate slice — Addendum
AA from each year's OPPS/ASC Final Rule.

## Payment formula (#722)

ASC screening rates use the calendar-year HCPCS payment weight and
ASC conversion factor, and the fiscal-year N IPPS wage index for
calendar year N. FY N starts 1 October of N−1. That is the wage index
numbered the same as the calendar year, not the fiscal year the
service date falls in. October–December of CY N still uses FY N.

```
payment_weight × ASC conversion factor × (labor_share × wage_index + (1 − labor_share))
```

The labor-related share is a sourced row in `corvid_cms_labor_shares`
(`payment_system` `asc`), shipped in `db/data/cms_labor_shares.csv`.
Operators load that file with `rake cms:labor_shares:import` before
repricing. After upgrading, operators must run
`rake cms:labor_shares:import` or OPPS/ASC prices fall to the stub.
Demo seeds insert the CY 2026 OPPS share; `PrcImporter.reanalyze` does
not load the file. Each row cites that calendar year's OPPS/ASC final
rule. The ASC labor-related share in that file is 50% for CY 2008–CY
2026. ASC CY 2007 has no row and is undetermined. A calendar year with
no row is undetermined:
`AscRateProvider.lookup_for` returns nil rather than pricing at a
100% labor share. When the ASC rate and conversion factor are loaded
and only the labor share is missing, the analyzer does not fall
through to OPPS; it takes the stub path and the note names the
missing ASC labor share. A missing ASC rate still falls through to
OPPS. Money is exact `BigDecimal`, rounded to cents once (ADR 0004).
When an IPPS wage-index row is used, the lookup records that row's
fiscal year and the labor share. When no wage-index row is loaded and
the index defaults to 1.0, `wage_index_fiscal_year` is nil and the
analyzer note is
`Wage index 1.0 (no FY N wage-index row), labor share X.`

## Source

The authoritative source for the ASC facility list is the **CMS
iQIES Provider of Services file** (HHA / ASC / Hospice — different
from the Hospital POS file used for CAH). Published quarterly at
data.cms.gov, ~175 MB CSV covering ~77K facilities; we filter to
ASCs (`prvdr_type_id = '11'`).

Dataset page:
https://data.cms.gov/provider-characteristics/hospitals-and-other-facilities/provider-of-services-file-internet-quality-improvement-and-evaluation-system

Direct download URL pattern:

```
https://data.cms.gov/sites/default/files/{YYYY-MM}/{uuid}/POS_File_iQIES_Q{n}_{year}.csv
```

The `data.cms.gov/data.json` catalog API lists every distribution.

### iQIES vs Hospital POS differences

- Column names are **lowercase** (`prvdr_num` vs `PRVDR_NUM`).
- Dates are **already YYYY-MM-DD** (vs YYYYMMDD in Hospital POS).
- Termination is encoded via the `trmntn_exprtn_dt` column content:
  active rows carry the literal string `"Not Available"`; terminated
  rows carry an ISO 8601 date. No separate termination-code column.
- Provider type is `prvdr_type_id`, not the `PRVDR_CTGRY_CD +
  PRVDR_CTGRY_SBTYP_CD` pair from the Hospital POS.

ASC CCNs use letter-prefix format (`17C0001897`) rather than the
6-digit numeric format Hospital CAH uses. Both pass through verbatim
as the `ccn` value.

## Canonical CSV shape

Same as CAH — `CmsFacilityListParser` consumes both:

```csv
# release_label: cms_iqies_2026q1
ccn,npi,facility_name,effective_date,end_date
17C0001897,,"FOUNDERS SURGERY CENTER, LLC",2022-06-01,
04C0001111,,ADVANCED INTERVENTIONAL PAIN - TEXARKANA ASC,2022-10-28,
```

- `npi` is blank (POS doesn't carry NPI; resolved at lookup time via
  the NPI ↔ CCN crosswalk — see
  [cms_npi_crosswalk_data.md](cms_npi_crosswalk_data.md))
- `effective_date` ← `orgnl_prtcptn_dt`
- `end_date` blank for active, ISO date for terminated

## Per-quarter normalization recipe

```bash
# 1. Find the latest iQIES POS file URL
curl -sL https://data.cms.gov/data.json \
  | jq -r '.dataset[] | select(.title | test("Provider of Services.*iQIES|Internet Quality")) | .distribution[].downloadURL' \
  | grep -iE "POS_File_iQIES_Q.*\.csv|ProviderOfService_iQIES_" | head -1

# 2. Download (~175 MB)
curl -sL "${POS_URL}" -o /tmp/cms_pos_iqies.csv

# 3. Normalize
bundle exec rails "cms:asc:normalize_pos[/tmp/cms_pos_iqies.csv,/tmp/asc_facilities_${QUARTER}.csv,cms_iqies_${QUARTER}]"

# 4. Upload to cms-fee-schedules-v1 release
gh release upload cms-fee-schedules-v1 /tmp/asc_facilities_${QUARTER}.csv \
  --repo lakeraven/corvid --clobber

# 5. Load via the existing import task
bundle exec rails "cms:asc:import_facilities[/tmp/asc_facilities_${QUARTER}.csv,cms_iqies_${QUARTER}]"
```

## Coverage status

| Snapshot | Active ASCs | Terminated | Total | Source |
|---|---:|---:|---:|---|
| 2026 Q1 | 6,593 | 1,762 | 8,355 | CMS iQIES `POS_File_iQIES_Q1_2026.csv` |

## Refresh cadence

Same as CAH: quarterly. ASC certifications change throughout the year;
the historical `effective_date` / `end_date` columns make a current-
quarter snapshot correct for any historical service date.

## Outstanding: ASC weight + CF data

This doc covers the **facility registry only**. ASC APC weights and
conversion factors come from a separate source (CMS OPPS Final Rule
Addendum AA per year). Until that loads:

- `AscFacility.applies?` matches correctly.
- `AscRateProvider.lookup_for` returns nil when no Addendum AA rate
  is loaded for that year and HCPCS.
- `analyze_outpatient` falls through to OPPS pricing when the ASC
  rate itself is missing. A loaded rate and conversion factor with
  no ASC labor share does not. After upgrading, operators must run
  `rake cms:labor_shares:import` or OPPS/ASC prices fall to the stub.

So today, registering an ASC vendor doesn't yet change the rate
they're priced against. Once Addendum AA data lands, ASC-routed claims
will produce ASC-specific Medicare-allowable rates. Tracked in #278.
