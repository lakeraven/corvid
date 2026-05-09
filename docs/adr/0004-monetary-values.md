# ADR 0004: Monetary values — money-rails, integer subunit-cents, per-row currency

**Status:** Proposed
**Date:** 2026-05-08

## Context

Corvid stores monetary values across at least eight tables — PRC obligations, PRC payments, PRC overpayment analyses, billing transactions, claim submissions, payments, fee schedule entries, and the Case-domain estimates/approvals. Today every column is `decimal(12, 2)` (or `decimal(8, 4)` for RVU/GPCI factors that aren't strictly monetary), and every service that emits these values has to format them by hand.

The PRC overpayment report (#286) hit this directly: `BigDecimal#to_s` defaults to scientific notation (`"0.42E5"`), which is hostile to CSV and JSON consumers. PR #292 patched it locally with a `fmt_money` helper, but the same hazard exists in every downstream service that will emit money — billing reports, claim ack files, recovery letters, REST/FHIR APIs.

A shared, type-aware representation of money would replace those per-service helpers, prevent silent unit confusion (cents vs dollars, dollars vs RVU rates, USD vs JOD subunits), and give the engine somewhere durable to put currency-aware behavior.

Constraints:

- Tenants today are US-domestic (IHS / PRC, USD-denominated), but the international roadmap (Inera Sweden in SEK, Jordan Hakeem in JOD, Nordic EHDS-adjacent partners in EUR) is concrete enough that a USD-only design would create debt within the year. Multi-currency from day one is cheaper than retrofitting later.
- A single corvid tenant operates in a single currency. PRC obligations and Swedish primary-care invoices do not appear together in one report or one transaction. Cross-currency arithmetic should fail loudly, not silently.
- Subunit assumptions vary: USD has 100 cents, JOD has 1000 fils, JPY has 0 subunits. Hardcoding "100" anywhere is wrong.
- Existing schema is `decimal(12, 2)`. Migrating to integer subunits is a backfill, not a data-loss event, but it touches every monetized column.
- Audit-ready report output (#286) must remain byte-stable; a money-type migration cannot silently change formatting in ways that would invalidate prior exports.

## Decision

1. **Adopt the `money-rails` gem** (which depends on `money` for the underlying type and ISO 4217 currency table). Models declare monetized accessors via `monetize`. Services and decorators consume `Money` objects directly; only adapter/serializer code at trust boundaries converts back to scalars.

2. **Storage convention: integer subunit-cents.** Every monetized column migrates from `decimal(12, 2)` to a `*_cents` integer column whose unit is the currency's smallest subdivision. The `money` gem looks up the subunit divisor from the ISO code, so `1000 cents` of JOD is 1 dinar, not 10. Code does not hardcode "100" anywhere.

   Rationale: integer subunits is the canonical pattern in production Rails apps (Stripe, Shopify, Mercury), eliminates floating-point rounding from arithmetic, and makes equality comparisons exact across currencies.

3. **Currency: per-row, locked at write.** Every monetized table gets one `currency_iso CHAR(3) NOT NULL DEFAULT 'USD'` column — not one column per money field, since the multiple money fields on a single row (e.g., `billed_amount`, `paid_amount`, `adjustment_amount` on a billing transaction) always share that row's currency by domain logic.

   The currency is set at write time from the tenant's default and is never updated. A 2009 USD payment reads back as USD even if the tenant later reconfigures its default. Historical records are immutable.

4. **Tenant has a `default_currency_iso`.** When a service constructs a `Money` value without specifying currency, it reads the tenant's default. Today every tenant defaults to `'USD'`; Sweden/Jordan tenants set their own when those onboardings happen. Writing a row whose `currency_iso` doesn't match the tenant's default emits a warning (configurable to raise) — catches the "I forgot to set up the Swedish tenant" footgun.

5. **money-rails wiring:** `monetize :amount_cents, as: :amount, with_model_currency: :currency_iso`. The gem reads each row's currency directly, so cross-row arithmetic on mixed currencies raises (`Money::Bank::UnknownRate` / `Money::IncompatibleCurrencyError`). That's a feature: it forces reports to handle multi-currency explicitly rather than silently summing apples + oranges.

6. **No FX. Reports group by currency.** A multi-tenant or multi-currency report displays per-currency totals (one section per ISO code), never an auto-converted "grand total." If FX is ever needed (rarely — IHS/PRC is USD, Inera is SEK, Hakeem is JOD; they don't mix on one report), it's an explicit operation against a stored FX-rate table with timestamp and source — that's a future ADR, not this one.

7. **Trust-boundary rules.** Money objects flow freely inside services, decorators, and view-side helpers. They do **not** cross these boundaries:
   - **Database wire format.** Integer subunit-cents + currency ISO are canonical storage; `Money` reconstructs from the pair on read.
   - **JSON / CSV / FHIR output.** Serializers convert to fixed-point string ("42000.00") for the value plus a separate `currency` field, never `BigDecimal#to_s`, never raw subunit-cents (a consumer who sees `42000` for a JOD field would mis-render it as 42 dinars instead of 42).
   - **RPMS RPC adapter.** RPMS does not know about `Money`; the adapter receives/emits decimals at the wire and converts at the edge.
   - **External APIs (Availity, claim files, FHIR).** Same — convert at the boundary, document the format used.

8. **Migration strategy: staged across PRs, not a single mega-PR.** Each PR follows the same recipe:
   - Add `*_cents` integer columns and `currency_iso` alongside existing decimals.
   - Backfill cents = decimal × subunit_factor (100 for USD-denominated existing rows); set currency_iso = 'USD' on existing rows.
   - Switch the model to `monetize :amount_cents, as: :amount, with_model_currency: :currency_iso`.
   - Update services to consume `Money`; update serializers to emit fixed-point strings via `Money#format` or explicit `to_s`.
   - Once all readers are on the new accessor, drop the legacy decimal column in a follow-up migration.

   Order: PRC obligations → PRC payments → PRC overpayment analyses → billing transactions → claim submissions → payments → Case-domain estimates/approvals. RVU/GPCI factors on `FeeScheduleEntry` stay decimal — they are rates, not money, and the math is unit-free.

## Consequences

### Positive

- One representation of money across the engine; type system catches unit confusion (cents vs dollars vs subunits, USD vs SEK vs JOD).
- Eliminates per-service `BigDecimal`-to-string formatting code (replaces the `fmt_money` / `serialize_money` helpers from #286).
- Integer-subunit storage gives exact arithmetic and stable equality across currencies.
- Per-row currency + locked-at-write makes historical records immutable across tenant reconfiguration.
- International expansion (Sweden, Jordan, Nordic EHDS) requires no schema change — only a new tenant with a different `default_currency_iso`.
- Trust-boundary rules give us a place to document and enforce serialization conventions.

### Negative

- Migration touches every monetized table — coordinated schema work, with a transitional period where both columns exist.
- New external dependency (`money-rails` and its dependency on `money`). Both stable and widely used, but still a supply-chain concern.
- Existing tests that assert against `BigDecimal` literals will need to update to `Money.from_amount` or equivalent.
- Code that compared raw decimals (`a + b == c.to_d`) needs updating; `Money == BigDecimal` is false even for matching numeric value.
- Reports that previously auto-summed across rows now must group by currency. Today every report is single-currency so this is invisible, but it's a behavior commitment.

### Alternatives considered

- **USD-only, defer multi-currency to a future ADR.** Cheap today, but the international roadmap is concrete enough (Inera Sweden, Jordan Hakeem, Nordic EHDS) that retrofitting per-row currency across already-shipped tables would cost more than designing for it now.
- **Tenant-default-only, no per-row column.** Simplest, but historical records would shift currency if a tenant ever reconfigures. Rare in healthcare, but a hard immutability story is cheap to keep and expensive to add later.
- **Decimal storage with `monetize :amount_decimal, as: :amount`.** Less invasive migration, but it's `money-rails`' secondary path and gives up the integer-subunit arithmetic guarantees that are the main reason to adopt the gem.
- **Hand-rolled `Corvid::Money` value object.** Lighter dependency story, but reinvents a battle-tested ISO 4217 currency table, subunit handling, formatting, and rounding policy. Maintenance cost beats the savings.
- **Adopt money-rails but auto-FX in reports.** Hides the "is this number meaningful?" question behind an FX rate that drifts daily. Production money apps (Stripe, Wise, Shopify) treat FX as an explicit, time-stamped operation; we should too if we ever need it.

## Migration notes

- The transitional period (both decimal and `*_cents` columns present, model still reads decimal) can be shortened by making each migration end-to-end: add columns + backfill + switch reader + drop decimal in one PR per table. For tribal/Phase-1 scale this fits in one transaction; if a table grows past that threshold the recipe splits cleanly.
- Tests need a small helper (`money(42_000, "USD")` shorthand) to keep test code readable.
- The `MoneyRails.configure` block sets `default_currency = nil` (forces every Money to specify currency explicitly) and registers the trust-boundary serializer.

## References

- #294 Adopt money-rails for monetary values across the engine
- #286 PRC overpayment report (Phase 1) — local fix this ADR supersedes
- #291 PRC overpayment report PDF rendering — will use Money's formatting helpers
- #293 SQL aggregation + streaming CSV — coordinate so SQL totals consume cents not decimals
- ADR 0002 Architectural foundations
- [money-rails README](https://github.com/RubyMoney/money-rails)
- [money gem (RubyMoney)](https://github.com/RubyMoney/money)
- [ISO 4217 currency codes](https://www.iso.org/iso-4217-currency-codes.html)
