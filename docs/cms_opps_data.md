# CMS OPPS Data Ingestion

The PRC overpayment analyzer prices hospital outpatient obligations
against real CMS OPPS (Outpatient Prospective Payment System) Final
Rule rates loaded into `corvid_opps_apc_weights` and
`corvid_opps_conversion_factors`. This doc covers where the source
data comes from, how it's normalized into the canonical CSV shape,
and how to ingest a year.

## Coverage target

CY 2008 through current year (matches the OPPS payment system's
useful range for tribal PRC recovery — earlier years are pre-OPPS or
have alternate rate systems).

## Source

CMS publishes annual **OPPS Final Rule** tables. The relevant artifact
is **Addendum A — OPPS APCs for CY {year}**, distributed as part of
the quarterly Web Addendum drops. The January Web Addendum carries
the Final Rule values for that calendar year.

URL pattern (current scheme, CY 2020+):

```
https://www.cms.gov/medicare/payment/prospective-payment-systems/hospital-outpatient/regulations-notices/cms-NNNN-fc
```

Where `cms-NNNN-fc` is the rule number for that year's Final Rule.
Known rule numbers:

| CY | Rule number |
| --- | --- |
| 2026 | CMS-1834-FC |
| 2025 | CMS-1809-FC |
| 2024 | CMS-1786-FC |
| 2023 | CMS-1772-FC |
| 2022 | CMS-1753-FC |
| 2021 | CMS-1736-FC |
| 2020 | CMS-1717-FC |

Older years (CY 2008–2019) use the legacy URL scheme under
`/Medicare/Medicare-Fee-for-Service-Payment/HospitalOutpatientPPS/`.

CMS distributes the Addendum A as a `.zip` containing both an
`.xlsx` and a `.csv` (in the `508 Version` subdirectory). The CSV
is easier to parse and has the same content as the xlsx; we
normalize from the CSV.

## Canonical CSV shape

Two files per year, named:

```
opps_apc_weights_CY{year}.csv
opps_conversion_factors_CY{year}.csv
```

APC weights:

```csv
# release_label: cms_opps_cy2026_final_rule
apc_code,relative_weight
2616,194.3993
2632,4.3354
5071,25.4378
...
```

Conversion factors (NATIONAL only in Phase 1; per-CBSA wage index
is a Phase 2 add):

```csv
# release_label: cms_opps_cy2026_final_rule
locality,conversion_factor,wage_index
NATIONAL,91.4150,1.0000
```

The leading `#`-comment line is the `release_label` marker — read by
`CmsOppsParser` and stripped before parsing.

## Per-year normalization recipe

```bash
# 1. Find the year's Final Rule home page (rule number from table above)
open "https://www.cms.gov/medicare/payment/prospective-payment-systems/hospital-outpatient/regulations-notices/cms-NNNN-fc"

# 2. Download the "January YYYY Web Addendum A" zip from the rule's
#    Downloads section (or click each Addendum A line). The zip
#    contains both .xlsx and a 508 Version .csv.

# 3. Extract to a local path
unzip january_${YEAR}_web_addendum_a.MM.DD.YY.zip -d /tmp/opps_${YEAR}/

# 4. Run the normalizer (corvid)
bundle exec rails "cms:opps:normalize_addendum_a[${YEAR},/tmp/opps_${YEAR}/508 Version January ${YEAR} Web Addendum A/January ${YEAR} Web Addendum A.MM.DD.YY.csv,/tmp/opps_apc_weights_CY${YEAR}.csv,cms_opps_cy${YEAR}_final_rule]"

# 5. Hand-write the conversion factor CSV (single line per year, NATIONAL only)
cat > /tmp/opps_conversion_factors_CY${YEAR}.csv <<CSV
# release_label: cms_opps_cy${YEAR}_final_rule
locality,conversion_factor,wage_index
NATIONAL,${OPPS_CF},1.0000
CSV

# 6. Upload both to the cms-fee-schedules-v1 release
gh release upload cms-fee-schedules-v1 \
  /tmp/opps_apc_weights_CY${YEAR}.csv \
  /tmp/opps_conversion_factors_CY${YEAR}.csv \
  --repo lakeraven/corvid --clobber

# 7. Fetch + import in the host app
rake cms:opps:fetch_release[${YEAR}]
```

## Known conversion factors

The OPPS national conversion factor (full-update, OQR-compliant
hospitals) is published in each year's Final Rule preamble:

| CY | Conversion factor | Source |
| --- | ---: | --- |
| 2026 | $91.4150 | CMS-1834-FC |
| 2025 | $89.1690 | CMS-1809-FC |
| 2024 | $87.3820 | CMS-1786-FC |
| 2023 | — | CMS-1772-FC (TBD) |
| 2022 | — | CMS-1753-FC (TBD) |
| 2021 | — | CMS-1736-FC (TBD) |
| 2020 | — | CMS-1717-FC (TBD) |

For hospitals subject to the 340B recoupment adjustment, the
conversion factor is slightly lower (CY 2026: $90.97 vs $91.415). We
ship the standard full-update CF in the canonical CSV. Per-hospital
340B-recouped pricing is a future enhancement (covered by deferred
adjudication-adjustments issue #321).

## Layout drift across years

CMS occasionally renames Addendum A columns. The normalizer resolves
columns by header label (APC, SI, Relative Weight) rather than fixed
position, so column-order shifts don't silently misread the weight.
A missing required column raises `MalformedFileError`.

Watch for in older years:

- Pre-CY 2008: APC system existed but the relative-weight column
  was sometimes named "Weight" rather than "Relative Weight". May
  require normalizer adjustment.
- ISO-8859-1 encoding throughout. The normalizer re-encodes to
  UTF-8 on read; if a year ships UTF-8 directly we'd be unaffected.

## Production ingest priority

By dollar volume in tribal PRC obligations:

1. CY 2026 — most recent claims; loaded today.
2. CY 2025–CY 2023 — recent recoverable years.
3. CY 2022–CY 2018 — older recoverable; statute of limitations varies.
4. CY 2017–CY 2008 — long-tail; stub fallback acceptable.

## Coverage status

| CY | Status | release_label | CF |
| --- | --- | --- | ---: |
| 2026 | **Real CMS data** | `cms_opps_cy2026_final_rule` | $91.4150 |
| 2025 | Stub fallback | — | $89.1690 (known) |
| 2024 | Stub fallback | — | $87.3820 (known) |
| 2023 | Stub fallback | — | TBD |
| 2022 | Stub fallback | — | TBD |
| 2021 | Stub fallback | — | TBD |
| 2020 | Stub fallback | — | TBD |
| 2019 | Stub fallback | — | TBD |
| 2018 | Stub fallback | — | TBD |
| 2017 | Stub fallback | — | TBD |
| 2016 | Stub fallback | — | TBD |
| 2015 | Stub fallback | — | TBD |
| 2014 | Stub fallback | — | TBD |
| 2013 | Stub fallback | — | TBD |
| 2012 | Stub fallback | — | TBD |
| 2011 | Stub fallback | — | TBD |
| 2010 | Stub fallback | — | TBD |
| 2009 | Stub fallback | — | TBD |
| 2008 | Stub fallback | — | TBD |

## Phase 2: per-CBSA wage index

Phase 1 ships NATIONAL-only with `wage_index=1.0`. Real OPPS pricing
applies a per-CBSA wage adjustment (the same wage-area data CMS uses
for IPPS). Loading per-CBSA rows is a separate slice — adds geographic
accuracy at the cost of a separate per-year sourcing step.

For tribal PRC recovery in rural/non-metro areas, the wage adjustment
is typically <5% — material but not game-changing. NATIONAL CF is
"directionally correct" until Phase 2 lands.

## ASC parity

Ambulatory Surgical Centers use the same APC codes but a separate
conversion factor (~60% of OPPS). When ASC backfill begins, the
sourcing pattern mirrors this doc — Addendum AA (ASC payment rates)
from each CMS-NNNN-FC. The same `Corvid::CmsOppsAddendumANormalizer`
won't work directly; ASC has its own column layout. Tracked in #278.
