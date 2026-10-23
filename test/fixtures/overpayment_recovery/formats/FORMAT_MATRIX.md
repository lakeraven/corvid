# RPMS PRC Fixture Format Matrix

These fixtures model reasonable PRC export variants we may see from RPMS
sites and ETL hops. Use them to drive parser/import compatibility tests.

## Files

- `standard_v1.prc`
  - Baseline `H/O/P/T` caret-delimited report (current expected format).
- `extended_fields_v1.prc`
  - Trailing fields added to `H`, `O`, `P`, and `T` records.
  - Verifies parser ignores appended columns safely.
- `payment_before_obligation_v1.prc`
  - `P` line arrives before its matching `O` line.
  - Verifies importer orphan/drop behavior and reconciliation logic.
- `no_trailer_v1.prc`
  - Header + obligation/payment records but no trailer line.
  - Verifies parser/importer behavior when trailer is omitted.
- `invalid_dates_v1.prc`
  - Malformed `YYYYMMDD` values in header/obligation/payment.
  - Verifies date parsing degrades to nil instead of exploding.
- `alternate_header_type_v2.prc`
  - Different header type token/version while keeping caret record structure.
  - Verifies parser is tolerant to source/version label drift.
- `malformed_no_header.prc`
  - No `H` record.
  - Verifies importer fails closed with `MalformedExportError`.
- `duplicate_ids_v1.prc`
  - Duplicate `obligation_id` and duplicate `payment_id` in one file.
  - Verifies upsert/uniq behavior and "last record wins" assumptions.
- `amount_precision_extremes_v1.prc`
  - Penny-scale values, >2-decimal values, and very large amounts.
  - Verifies cent conversion, rounding, and numeric stability.
- `unknown_record_types_v1.prc`
  - Interleaves unknown record tags (`X/Y/Z`) with valid rows.
  - Verifies parser safely ignores unknown row types.
- `unmapped_facility_v1.prc`
  - Header facility code not in facility dictionary (`XYZ`).
  - Verifies analyzer returns `:unmapped_facility` paths.

## Notes

- All fixtures intentionally keep the same first-field record tags (`H/O/P/T`),
  because the current parser dispatches on that token.
- If future sites emit truly different row schemas (e.g., CSV/pipe/JSON),
  add a separate parser and sibling fixture family rather than overloading
  this one.
