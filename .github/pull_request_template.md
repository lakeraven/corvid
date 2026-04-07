## Summary
<!-- One paragraph: what does this PR do and why? -->

## Linked issue
<!-- Closes #N or Refs #N -->

## ADR compliance
<!-- Check all that apply. If you're introducing a new architectural decision, add an ADR. -->

- [ ] No new `*_id` columns for external/opaque references (use `*_identifier` per ADR 0001)
- [ ] No new PHI columns at rest — free text uses `*_token` resolved via adapter (per ADR 0003)
- [ ] All new tables/models use `corvid_*` table prefix (per ADR 0002)
- [ ] Tenant context honored — new queries don't bypass `default_scope` (per ADR 0002)
- [ ] String enums + PG CHECK constraints for any new status columns (per ADR 0002)
- [ ] Polymorphic same-tenant validation if introducing a new polymorphic model
- [ ] No direct references to host models (`Patient`, `Practitioner`, `Provenance`, etc.) — use adapter or hooks
- [ ] If introducing a new design decision, an ADR is added in `docs/adr/`

## Test plan
<!-- How was this verified? -->

- [ ] `bundle exec rake test` passes locally
- [ ] New tests added for new behavior (TDD: red → green per commit)
- [ ] Tests use `Corvid::TenantContext.with_tenant(...)` for isolation
- [ ] Test fixtures use synthetic strings (`TEST,PATIENT 001`, not realistic names) per ADR 0003

## Notes for reviewers
<!-- Anything risky, surprising, or worth a closer look? -->
