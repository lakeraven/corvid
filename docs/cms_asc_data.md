# CMS ASC Registry Ingestion

The PRC overpayment analyzer routes outpatient (APC-mapped) claims to
**ASC pricing** (lower CF than OPPS) when the obligation's vendor is
on the CMS Ambulatory Surgical Center registry on the service date.

This doc covers the ASC **facility registry** sourcing. The ASC APC
weight + conversion factor data is a separate slice — Addendum AA
from each year's OPPS Final Rule.

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

- `npi` is blank (POS doesn't carry NPI; NPPES cross-walk = separate step)
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
- `AscRateProvider.lookup_for` returns nil for every (year, APC).
- `analyze_outpatient` falls through to OPPS pricing.

So today, registering an ASC vendor doesn't yet change the rate
they're priced against. Once Addendum AA data lands, ASC-routed claims
will produce ASC-specific Medicare-allowable rates. Tracked in #278.
