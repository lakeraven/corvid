# CMS CAH Registry Ingestion

The PRC overpayment analyzer applies a **1.01× multiplier** to the
Medicare-allowable rate when an obligation's vendor is on the CMS
Critical Access Hospital list on the service date. CMS pays CAHs at
101% of reasonable cost; for PRC MLR purposes the same 1.01× ceiling
applies on top of the otherwise-computed PFS/IPPS/OPPS/ASC rate.

This doc covers where the source data comes from, how it's normalized
into the canonical CAH list CSV shape, and how to ingest a quarter.

## Source

The authoritative source is the **CMS Provider of Services (POS)
Hospital and Other Facilities file**, published quarterly at
data.cms.gov. ~30 MB CSV covering ~45K facilities; we filter to CAHs
(provider category 01 + subtype 11).

Dataset page:
https://data.cms.gov/provider-characteristics/hospitals-and-other-facilities/provider-of-services-file-hospital-non-hospital-facilities

Direct download URLs follow the pattern:

```
https://data.cms.gov/sites/default/files/{YYYY-MM}/{uuid}/Hospital_and_other.DATA.Q{n}_{year}.csv
```

The `data.cms.gov/data.json` catalog API lists every distribution; use
that to find the latest URL programmatically.

### Why not the Flex Monitoring Team list

`flexmonitoring.org` publishes a clean CAH-only list, but it's keyed
by facility name + state + zip — no CCN. Our `CahFacility.applies?`
matches on CCN/NPI, so we need a CCN-keyed source. The CMS POS file
has CCN (`PRVDR_NUM`) directly.

## Canonical CSV shape

The same shape `CmsFacilityListParser` consumes (also used by ASC):

```csv
# release_label: cms_pos_2026q1
ccn,npi,facility_name,effective_date,end_date
011300,,WASHINGTON COUNTY HOSPITAL,2002-11-01,
011301,,ATMORE COMMUNITY HOSPITAL,2005-07-01,2008-03-31
```

- `npi` is blank — POS file doesn't carry NPI. Cross-walk from NPPES
  is a separate step (not yet implemented).
- `effective_date` anchors to `ORGNL_PRTCPTN_DT` (the original
  Medicare-CAH certification date), not `CRTFCTN_DT` (which changes on
  re-survey events).
- `end_date` is blank for active CAHs (`PGM_TRMNTN_CD = '00'`),
  populated from `TRMNTN_EXPRTN_DT` for terminated facilities.

## Per-quarter normalization recipe

```bash
# 1. Find the latest POS Hospital file URL from the catalog
curl -sL https://data.cms.gov/data.json \
  | jq -r '.dataset[] | select(.title | test("Provider of Services.*Quality")) | .distribution[].downloadURL' \
  | grep -i Hospital_and_other | head -1

# 2. Download (~30 MB)
curl -sL "${POS_URL}" -o /tmp/cms_pos_hospital.csv

# 3. Normalize
bundle exec rails "cms:cah:normalize_pos[/tmp/cms_pos_hospital.csv,/tmp/cah_facilities_${QUARTER}.csv,cms_pos_${QUARTER}]"

# 4. Upload to cms-fee-schedules-v1 release
gh release upload cms-fee-schedules-v1 /tmp/cah_facilities_${QUARTER}.csv \
  --repo lakeraven/corvid --clobber

# 5. Load via the existing import task
bundle exec rails "cms:cah:import[/tmp/cah_facilities_${QUARTER}.csv,cms_pos_${QUARTER}]"
```

The import operation is canonical-snapshot semantics: rows tagged with
the incoming `source_release` are wiped before insert. Cross-release
conflicts on `(ccn, effective_date)` are replaced (newer publication
wins). Manual rows tagged with a different `source_release` survive
unless they conflict on the identifier dimension.

## Coverage status

| Snapshot | Active CAHs | Terminated | Total | Source |
|---|---:|---:|---:|---|
| 2026 Q1 | 1,386 | 140 | 1,526 | CMS POS `Hospital_and_other.DATA.Q1_2026.csv` |

## Refresh cadence

POS is published quarterly. CAH status changes (new certifications,
terminations) happen throughout the year. For tribal PRC recovery
work spanning multiple service dates, the historical effective_date /
end_date columns are what matter — a current-quarter snapshot covers
historical claims correctly because each row records when it was
effective.

Recommended cadence: refresh annually unless tribal customers report
vendor mismatches.

## NPI cross-walk (future)

POS file doesn't carry NPI. If PRC obligations arrive keyed by NPI
rather than CCN, `CahFacility.applies?` won't match. Two paths:

1. **Cross-walk via NPPES** — the National Plan and Provider
   Enumeration System has a public CSV mapping NPI ↔ CCN. Adds a
   second normalization step.
2. **Customer-side conversion** — tribal IT translates NPI to CCN
   before importing PRC obligations.

For Yakama/Skokomish-shape customers we'll know which keying is in
use after the first PRC export goes through the analyzer.
