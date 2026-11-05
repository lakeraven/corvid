# Payer authorization rules

A tenant keeps its own rules for whether a payer requires authorization
before a service. `Corvid::PayerAuthorizationRuleLoader.load!` replaces
that tenant's rows from a CSV. `Corvid::PayerAuthorizationRequirement.lookup`
answers one service on one day. Another tenant's rules never match.

No matching rule is **unknown**. It is never `not_required`. Unknown and
conflict are lookup outcomes. They are not values stored on a row.

## CSV format

The first row is the header, in this order, with these names:

```csv
payer_identifier,service_code,code_from,code_to,place_of_service,plan_identifier,requirement,effective_on,expires_on
```

| Column | Meaning |
| --- | --- |
| `payer_identifier` | Payer the rule applies to. Required. Not blank. |
| `service_code` | One service code. Leave blank when the row is a range. |
| `code_from` | Inclusive start of a code range. Blank when `service_code` is set. |
| `code_to` | Inclusive end of a code range. Blank when `service_code` is set. |
| `place_of_service` | Place of service. Blank means any place. |
| `plan_identifier` | Plan. Blank means any plan for that payer. |
| `requirement` | One of the three values below. |
| `effective_on` | First day the rule is in force, `YYYY-MM-DD`. Required. |
| `expires_on` | Last day the rule is in force, `YYYY-MM-DD`. Blank means it does not expire. Must be on or after `effective_on`. |

A row uses exactly one code form. Set `service_code` and leave
`code_from` and `code_to` blank, or leave `service_code` blank and set
both `code_from` and `code_to`. A range is inclusive. Both ends are the
same length, `code_from` sorts before or on `code_to` as strings, and
both ends share one character pattern. Each position is a digit in
both codes or a letter in both codes. `10000` through `69999` is five
digits. `J0000` through `J9999` is a letter and four digits. `0001F`
through `9999F` is four digits and a letter. A range from `10000` to
`6999F` is invalid, because the last position is a digit on one end
and a letter on the other. A range covers a code only when the code
has that same digit-versus-letter pattern and, at every position
where both endpoints have the same letter, the code has that letter.
`0001F` through `9999F` covers `2033F`, not `0001T` or `2033G`.
`J0000` through `J9999` covers `J1234`, not `K1234`. `A0000` through
`C9999` covers `B1234`.

Every data row has exactly as many cells as the header. A row with
more cells or fewer cells is invalid. The loader names that row and
does not repeat the cell values. Nothing from that file is loaded. A
completely blank line after the last data row is ignored.

Codes are five characters from `A`–`Z` and `0`–`9` (`^[A-Z0-9]{5}$`).
The loader strips surrounding whitespace and upcases codes before it
stores them. A lowercase code in the file is accepted only once it
upcases into that shape. A cell that is only whitespace, including
characters such as U+00A0 that Ruby `strip` leaves behind, is blank.
Surrounding whitespace, including tabs, is stripped. A control
character left inside a cell is invalid. The loader names the row and
the column's place in the header, counting the first column as 1, and
does not repeat the cell. Nothing from that file is loaded.

Dates are strict ISO calendar days: four-digit year, two-digit month,
two-digit day, hyphen-separated. `2025-1-1` and `2025/01/01` are
rejected. `2025-02-30` is rejected. Blank `place_of_service`,
`plan_identifier`, `expires_on`, and the unused code columns mean
"any" or "none", as the column describes. A blank `payer_identifier`,
`requirement`, or `effective_on` is invalid.

### Requirement values

| Value | Meaning |
| --- | --- |
| `required` | Authorization is required. |
| `not_required` | Authorization is not required. |
| `documentation_only` | Documentation is required; this is not a full authorization hold. |

Any other requirement text is invalid. The loader names the row and the
column and does not repeat the cell.

## Load

`Corvid::PayerAuthorizationRuleLoader.load!(path_or_io, tenant_identifier:)`
reads a file path or an IO. A blank `tenant_identifier` raises
`ArgumentError`. A missing path, a directory, or an IO that cannot
be read raises `InvalidFile`. A read that raises `IOError` or an
encoding error is the same failure. That message says the file could
not be read and does not include the path, the underlying error, or
any cell. Nothing is changed. A malformed file is `InvalidFile` as
well, and that message does not include the file's text.

The file replaces that tenant's rules all or nothing. Every row is
checked before any row is written. When a row is invalid, nothing from
that file is loaded and the tenant's previous rules stay. A row that
fails while it is saved is invalid too. The loader names the row and,
when it knows which, the column, and does not repeat the cell. An
`ArgumentError` from the save, such as a driver rejecting a string
the cell check did not catch, is the same kind of failure and names
the row. The transaction rolls back, so the tenant's previous rules
stay.

When the file is valid, the tenant's existing rules are deleted and
the file's rows are inserted in one transaction. Loads for one tenant
are serialized. Before deleting, the loader takes a transaction-scoped
lock keyed by that tenant, so one load finishes before the next load
for that tenant deletes and inserts. The later file wins entirely.
The lock keys are hashtext values, which can collide, so two tenants
may occasionally serialize, but a load never touches another tenant's
rows. A header-only file is valid and clears that tenant's rules.
Other tenants are left untouched. The return value is the number of
rows loaded.

## Lookup

```ruby
Corvid::PayerAuthorizationRequirement.lookup(
  payer_identifier:,
  service_code:,
  place_of_service:,
  plan_identifier:,
  on:,
  tenant_identifier: Corvid::TenantContext.current_tenant_identifier
)
```

`on` must be a `Date` (`instance_of?(Date)`). A time, a string, or nil
is unknown. A blank payer, a blank tenant, or a service code that is
not five uppercase letters or digits after stripping and upcasing is
unknown. The query filters on the `tenant_identifier` argument. It does
not use the thread's tenant, so a lookup can name a tenant while the
thread is set to another, or while no tenant is set.

A rule matches when all of these hold:

- The payer is the rule's payer.
- The day is on or after `effective_on`, and on or before `expires_on`
  when `expires_on` is set. Both ends are inclusive.
- The code equals `service_code`, or the range covers it. A range
  covers a code only when the code has the endpoints' digit-versus-letter
  pattern and, at every position where both endpoints have the same
  letter, the code has that letter. It also has to fall inside
  `code_from` .. `code_to` in string order, including the endpoints.
  A five-digit range does not cover a code with a letter in it.
  `10000` through `69999` does not cover `2033F`. `J0000` through
  `J9999` covers `J1234` and does not cover `K1234`. `0001F` through
  `9999F` covers `2033F` and does not cover `0001T` or `2033G`.
  `A0000` through `C9999` covers `B1234`, because those endpoints do
  not share a letter in the first position.
- `place_of_service` on the rule is blank, or it equals the place asked
  about. A blank place on the call matches only rules that leave place
  blank.
- `plan_identifier` on the rule is blank, or it equals the plan asked
  about. A blank plan on the call matches only rules that leave plan
  blank.

Specificity is the partial order of three independent flags: the rule
names a plan, the rule names a place of service, and the rule names an
exact `service_code` rather than a range. A rule dominates another when
it is at least as specific on every flag and stricter on one. The
deciding rules are the matching rules that nothing else dominates. A
plan-specific rule beats a payer-wide rule. A place-specific rule beats
a payer-wide rule. A rule that names both plan and place beats a rule
that names only one of them. An exact code beats an overlapping range
at the same plan and place. A plan-only rule and a place-only rule are
equally specific; neither wins on specificity alone.

When every deciding rule names the same requirement, that requirement
is the answer, and `rule_ids` lists those rules. When they disagree,
the answer is **conflict** and `rule_ids` lists the deciding rules.
When nothing matches, the answer is **unknown** and `rule_ids` is
empty. Unknown is never rewritten to `not_required`.

### Missing place or plan

A nil or blank `place_of_service` is not a claim that every place is
covered. If a rule matches on the other dimensions, names a place, and
states a different requirement than the answer computed without it, the
answer is **unknown**. The same fail-closed rule applies to a nil or
blank `plan_identifier`. A more specific rule that names the same
requirement does not force unknown. Asking about a different place or
plan does not consult the rule that names some other value; only an
omitted place or plan opens this check.
