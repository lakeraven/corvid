# frozen_string_literal: true

# State carried between steps: { tenant_id => Money instance }
@multi_currency_billed ||= {}

Given("a tenant {string} denominated in {string}") do |tenant_id, iso|
  @tenants ||= {}
  @tenants[tenant_id] = iso
end

When("I record a PRC obligation billed at {float}") do |amount|
  raise "no tenant set" if @tenants.nil? || @tenants.empty?
  tenant_id, iso = @tenants.first
  Corvid::TenantContext.with_tenant(tenant_id) do
    @obligation = Corvid::PrcObligation.create!(
      facility_identifier: "FAC",
      obligation_id: "OBL-#{iso}-#{SecureRandom.hex(4)}",
      billed_amount: Money.from_amount(amount, iso),
      currency_iso: iso,
      fiscal_year: 2026,
      imported_at: Time.current
    )
  end
end

Then("the obligation's billed_amount_cents is {int}") do |cents|
  assert_equal cents, @obligation.billed_amount_cents
end

Then("the obligation's currency_iso is {string}") do |iso|
  assert_equal iso, @obligation.currency_iso
end

Then("reading the obligation back yields Money of {float} {word}") do |amount, iso|
  Corvid::TenantContext.with_tenant(@tenants.keys.first) do
    reloaded = Corvid::PrcObligation.find(@obligation.id)
    assert_equal Money.from_amount(amount, iso), reloaded.billed_amount
  end
end

When("I try to add the USD obligation and the JOD obligation") do
  Corvid::TenantContext.with_tenant("tnt_yakama") do
    @usd_ob = Corvid::PrcObligation.create!(
      facility_identifier: "SEA",
      obligation_id: "OBL-USD-#{SecureRandom.hex(4)}",
      billed_amount: Money.from_amount(100, "USD"),
      currency_iso: "USD",
      fiscal_year: 2026,
      imported_at: Time.current
    )
  end
  Corvid::TenantContext.with_tenant("tnt_hakeem") do
    @jod_ob = Corvid::PrcObligation.create!(
      facility_identifier: "AMM",
      obligation_id: "OBL-JOD-#{SecureRandom.hex(4)}",
      billed_amount: Money.from_amount(100, "JOD"),
      currency_iso: "JOD",
      fiscal_year: 2026,
      imported_at: Time.current
    )
  end
end

Then("the engine raises a cross-currency error") do
  assert_raises(Money::Bank::UnknownRate) do
    @usd_ob.billed_amount + @jod_ob.billed_amount
  end
end
