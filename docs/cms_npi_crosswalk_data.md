# NPI ↔ CCN Crosswalk Ingestion

The CMS Provider of Services (POS) files that feed `corvid_cah_facilities`
and `corvid_asc_facilities` are keyed by CCN only — they don't carry NPI.
Tribal PRC exports may key vendor identifiers by either CCN or NPI
depending on the EHR source. Without a crosswalk, `CahFacility.applies?`
and `AscFacility.applies?` miss every NPI-keyed vendor, the 1.01× CAH
multiplier never fires, and ASC routing falls back to OPPS rates.

`corvid_npi_ccn_crosswalks` closes that gap. `applies?` consults it at
lookup time: when `vendor_id` is an NPI, it resolves to the CCN(s) the
NPI was billing under on the service date and matches those against the
facility list.

## Source

The authoritative source is the **CMS National Plan and Provider
Enumeration System (NPPES)** monthly file, published at
download.cms.gov. ~10 GB CSV covering every NPI ever issued.

Dataset page: https://download.cms.gov/nppes/NPI_Files.html

We don't load the full file — only the rows whose CMS Other Provider
Identifier (the CCN) already appears in one of the facility lists.

## Canonical CSV shape

```csv
npi,ccn,effective_date,end_date
1234567890,451301,2015-01-01,
9876543210,451999,2020-01-01,2024-12-31
```

- `effective_date` / `end_date` come from the NPPES history for the
  (NPI, CCN) tuple. Multiple historical periods per NPI are expected
  for organizational restructure / ownership change cases.
- `end_date` blank means the (NPI, CCN) tuple is still active.

## Refresh recipe

```bash
# 1. Pull the monthly NPPES file (~10 GB)
curl -sL "${NPPES_URL}" -o /tmp/nppes_$(date +%Y%m).zip

# 2. Filter + normalize to canonical CSV against the CCNs we care about.
#    (A standalone normalizer lives outside this engine — the corvid
#    side just consumes the canonical CSV.)

# 3. Upload to cms-fee-schedules-v1 release
gh release upload cms-fee-schedules-v1 /tmp/npi_ccn_crosswalk_${LABEL}.csv \
  --repo lakeraven/corvid --clobber

# 4. Load
bundle exec rails "cms:nppes:import_crosswalk[/tmp/npi_ccn_crosswalk_${LABEL}.csv,nppes_${LABEL}]"
```

Snapshot semantics: re-importing under the same `release_label` wipes
that label's prior snapshot before insert. Other labels are untouched,
so multiple historical NPPES snapshots can coexist.

## Refresh cadence

NPPES is published monthly. NPI ↔ CCN relationships change when a
facility changes ownership or restructures. For PRC recovery work,
the historical `effective_date` / `end_date` columns are what matter —
a current snapshot prices historical claims correctly.

Recommended cadence: refresh quarterly alongside the POS files.
