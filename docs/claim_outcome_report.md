# Claim outcome report

`Corvid::ClaimOutcomeReport` summarizes claim outcomes for one tenant over a service-date range. An optional facility identifier, an optional payer identifier, or both narrow the claims. Claims outside the range, claims with no service date, and any other tenant's claims are left out.

Every read runs inside `Corvid::TenantContext.with_tenant` for that tenant and also filters on `tenant_identifier`, so the tenant still holds if the default scope changes. The caller's previous tenant context is restored afterward, including when none was set. The report reads claim ids, statuses, service dates, payer and facility identifiers, and denial reason codes. It does not read patient identifiers, token columns, or amounts, and it writes nothing.

Rows are grouped by payer identifier, facility identifier, and the first day of the service-date month. A nil payer or facility stays as its own group. Order is month, then payer, then facility, with nils first.

Rejections and denials are never combined into one count, rate, or column.

`claims_sent` is the number of claims in the group that were sent (`submitted_at` is set).

`rejected_claims` is how many of those sent claims were rejected at least once (`rejected_at` is set).

`rejection_rate` is rejected claims divided by claims sent, as a percentage rounded to one decimal, or 0.0 when no claims were sent.

`adjudicated_claims` is claims the payer adjudicated: paid, or denied at least once. A claim rejected at the front end and later paid counts here as a non-denial.

`denied_claims` is how many adjudicated claims were denied at least once (`denied_at` is set).

`denial_rate` is denied claims divided by adjudicated claims, as a percentage rounded to one decimal, or 0.0 when no claims were adjudicated.

`outcome_claims` is claims with an outcome: paid, rejected at least once, or denied at least once.

`first_pass_claims` is claims paid without ever being rejected or denied.

`first_pass_rate` is first-pass claims divided by outcome claims, as a percentage rounded to one decimal, or 0.0 when no claim has an outcome.

`finalized_claims` is claims whose status is paid, rejected, or denied.

`paid_claims` is claims whose status is paid.

`payment_rate` is paid claims divided by finalized claims, as a percentage rounded to one decimal, or 0.0 when no claims are finalized.

Each count, and each rate's numerator and denominator, can be opened to the claim ids behind it. Those ids match the count.

Denied claims are also split by CARC category. `Corvid::Rcm::AdjustmentReasonCodes` maps a code to a work queue. An unmapped code is its own `unmapped` bucket and is not dropped. A denied claim with no codes is `uncoded`. A claim counts once in each distinct category it hits. A known RARC is skipped, and a denied claim with only RARCs is `uncoded`.

`to_csv` prefixes a string cell that begins with `=`, `+`, `-`, `@`, a tab, or a carriage return with a single quote.
