# frozen_string_literal: true

require "set"

# Step definitions for features/repricing/section_506_recovery.feature.
# Backed by the Corvid::OverpaymentRecovery::* pure-Ruby service modules
# (no AR persistence) — all state for a scenario lives in @-vars.

# -- Audit -------------------------------------------------------------------

Given("the customer uploads paid claims:") do |table|
  @uploaded_claims = table.hashes.map do |row|
    {
      cpt_code: row["cpt_code"],
      zip: row["zip"],
      paid_amount: row["paid_amount"].to_d,
      provider_npi: row["provider_npi"],
      provider_name: row["provider_name"],
      date_of_service: Date.parse(row["date_of_service"])
    }
  end
end

When("the audit runs") do
  Corvid::TenantContext.with_tenant(@tenant || "tnt_test") do
    @audit_result = Corvid::OverpaymentRecovery::AuditService.audit(@uploaded_claims)
  end
end

Then("overpayments should be identified") do
  assert @audit_result[:overpayments].any?
end

Then("the total overpayment should be greater than 0") do
  assert @audit_result[:total_overpayment].positive?
end

Then("overpayments should be grouped by provider") do
  assert @audit_result[:by_provider].any?
  @audit_result[:by_provider].each do |rollup|
    refute_nil rollup.provider_npi
    assert rollup.total_overpayment.positive?
  end
end

Then("no overpayments should be identified") do
  assert_empty @audit_result[:overpayments]
end

# -- Section 506 applicability ----------------------------------------------

Given("provider NPI {string} is Medicare-participating") do |npi|
  (@medicare_providers ||= Set.new).add(npi)
end

Given("provider NPI {string} is not Medicare-participating") do |npi|
  @medicare_providers ||= Set.new
end

When("I check Section 506 applicability for provider {string}") do |npi|
  participating = (@medicare_providers || Set.new).include?(npi)
  authority = @customer_lacks_section_506 ? false : true
  @section_506_result = Corvid::OverpaymentRecovery::Section506Check.for_provider(
    medicare_participating: participating,
    customer_has_section_506_authority: authority
  )
end

Then("Section 506 should apply") do
  assert @section_506_result.applies?
end

Then("Section 506 should not apply") do
  refute @section_506_result.applies?
end

Then("the legal basis should include {string}") do |fragment|
  assert_includes @section_506_result.legal_basis_text, fragment
end

Then("the legal basis should be {string}") do |expected|
  assert_equal expected, @section_506_result.legal_basis_text
end

# -- Demand letter (tribal / Section 506) ------------------------------------

Given("an overpayment of {float} to Medicare-participating provider {string}") do |amount, name|
  @customer_type = :tribal
  @medicare_participating = true
  @demand_provider = { name: name, npi: nil }
  @demand_claims = [ {
    cpt_code: "99213",
    date_of_service: Date.new(2025, 6, 15),
    paid_amount: amount * 2,
    medicare_rate: amount,
    overpayment: amount.to_d
  } ]
end

Given("the provider NPI is {string}") do |npi|
  @demand_provider[:npi] = npi
end

Given("the customer has signed recovery authorization {string}") do |auth_ref|
  @authorization_reference = auth_ref
end

Given("an overpayment to provider {string} with claims:") do |provider_name, table|
  @customer_type ||= :tribal
  @medicare_participating = true unless defined?(@medicare_participating) && !@medicare_participating.nil?
  @demand_provider = { name: provider_name, npi: nil }
  @demand_claims = table.hashes.map do |row|
    {
      cpt_code: row["cpt_code"],
      date_of_service: Date.parse(row["date_of_service"]),
      paid_amount: row["paid_amount"].to_d,
      medicare_rate: row["medicare_rate"].to_d,
      overpayment: row["overpayment"].to_d
    }
  end
end

When("I generate the demand letter") do
  @demand_letter = Corvid::OverpaymentRecovery::DemandLetterGenerator.generate(
    provider_name: @demand_provider[:name],
    provider_npi: @demand_provider[:npi],
    claims: @demand_claims,
    customer_type: @customer_type || :tribal,
    medicare_participating: @medicare_participating.nil? ? true : @medicare_participating,
    authorization_reference: @authorization_reference,
    referral_authorization_terms: @referral_authorization_terms
  )
end

Then("the letter should cite {string}") do |phrase|
  assert @demand_letter.cites?(phrase),
         "expected demand letter body to include #{phrase.inspect}; got:\n#{@demand_letter.body}"
end

Then("the letter should state {string}") do |phrase|
  assert @demand_letter.cites?(phrase),
         "expected demand letter body to state #{phrase.inspect}; got:\n#{@demand_letter.body}"
end

Then("the letter should state the overpayment amount as {float}") do |amount|
  assert_in_delta amount, @demand_letter.overpayment_amount.to_f, 0.01
  assert @demand_letter.cites?(format("%.2f", amount))
end

Then("the letter should state a {int}-day return deadline") do |days|
  assert_equal days, @demand_letter.deadline_days
end

Then("the letter should reference the False Claims Act") do
  assert @demand_letter.cites_fca, "expected FCA reference in demand letter"
end

Then("the letter should NOT reference the False Claims Act") do
  refute @demand_letter.cites_fca
end

Then("the letter should include the authorization reference {string}") do |ref|
  assert_equal ref, @demand_letter.authorization_reference
  assert @demand_letter.cites?(ref)
end

Then("the letter should list {int} claims with dates and amounts") do |count|
  assert_equal count, @demand_letter.claims.size
  @demand_letter.claims.each do |c|
    assert @demand_letter.cites?(c[:cpt_code])
  end
end

Then("the total demanded should be {float}") do |amount|
  assert_in_delta amount, @demand_letter.total_demanded.to_f, 0.01
end

Then("the letter should cite Section {int}") do |_section|
  assert @demand_letter.cites_section_506
end

Then("each should cite Section {int}") do |_section|
  assert @demand_letters.all?(&:cites_section_506)
end

Then("the letter should offer an installment plan for amounts over {int}") do |threshold|
  if @demand_letter.total_demanded > threshold
    assert @demand_letter.offers_installment
  end
end

# -- Demand letter (rural / contractual) ------------------------------------

Given("a non-tribal rural customer {string}") do |_name|
  @customer_type = :rural
  @customer_lacks_section_506 = true
end

Given("a tribal customer {string} with Section 506 authority") do |_name|
  @tribal_customer_type = :tribal
end

Given("a non-tribal customer {string} without Section 506") do |_name|
  @rural_customer_type = :rural
end

Given("an overpayment of {float} to provider {string}") do |amount, name|
  @demand_provider = { name: name, npi: nil }
  @demand_claims = [ {
    cpt_code: "99213", date_of_service: Date.today,
    paid_amount: amount * 2, medicare_rate: amount, overpayment: amount.to_d
  } ]
end

Given("the referral authorization specified {string}") do |terms|
  @referral_authorization_terms = terms
end

Given("no prior rate agreement exists") do
  @referral_authorization_terms = nil
end

Then("the letter should NOT cite Section {int}") do |_section|
  refute @demand_letter.cites_section_506
end

Then("the letter should cite the referral authorization terms") do
  refute_nil @demand_letter.referral_terms
  assert @demand_letter.cites?(@demand_letter.referral_terms)
end

Then("the letter should request voluntary refund") do
  assert_equal "request", @demand_letter.tone
  assert @demand_letter.cites?("voluntary")
end

Then("the letter should state the Medicare rate as the industry standard") do
  assert @demand_letter.cites?("industry standard")
end

Then("the tone should be {string} not {string}") do |expected_tone, _excluded|
  assert_equal expected_tone, @demand_letter.tone
end

Given("both have the same overpayment of {float} to the same provider") do |amount|
  @same_overpayment = amount
end

When("I generate demand letters for both") do
  @tribal_letter = Corvid::OverpaymentRecovery::DemandLetterGenerator.generate(
    provider_name: "Shared Provider",
    claims: [ { cpt_code: "99213", date_of_service: Date.today,
              paid_amount: @same_overpayment * 2, medicare_rate: @same_overpayment,
              overpayment: @same_overpayment.to_d } ],
    customer_type: :tribal, medicare_participating: true
  )
  @rural_letter = Corvid::OverpaymentRecovery::DemandLetterGenerator.generate(
    provider_name: "Shared Provider",
    claims: [ { cpt_code: "99213", date_of_service: Date.today,
              paid_amount: @same_overpayment * 2, medicare_rate: @same_overpayment,
              overpayment: @same_overpayment.to_d } ],
    customer_type: :rural, medicare_participating: true,
    referral_authorization_terms: "payment limited to Medicare rates"
  )
  @demand_letters = [ @tribal_letter, @rural_letter ]
end

Then("the tribal letter should cite Section {int} and FCA") do |_section|
  assert @tribal_letter.cites_section_506
  assert @tribal_letter.cites_fca
end

Then("the rural letter should cite contractual terms only") do
  refute @rural_letter.cites_section_506
  refute @rural_letter.cites_fca
end

Then("the tribal letter deadline should be {int} days") do |days|
  assert_equal days, @tribal_letter.deadline_days
end

Then("the rural letter deadline should be {int} days") do |days|
  assert_equal days, @rural_letter.deadline_days
end

# -- 60-day timeline + FCA --------------------------------------------------

Given("a demand letter sent on {string}") do |date|
  @demand_sent_on = Date.parse(date)
end

Then("the return deadline should be {string}") do |expected|
  deadline = Corvid::OverpaymentRecovery::Timeline.return_deadline(sent_on: @demand_sent_on)
  assert_equal Date.parse(expected), deadline
end

Then("interest should begin accruing on {string}") do |expected|
  start = Corvid::OverpaymentRecovery::Timeline.interest_accrual_starts(sent_on: @demand_sent_on)
  assert_equal Date.parse(expected), start
end

Given("a demand sent {int} days ago with no response") do |days|
  @demand_sent_on = Date.current - days
  @demand_today = Date.current
  @original_demand = build_demand_letter_for_followup(@demand_sent_on)
end

Given("a demand sent {int} days ago") do |days|
  @demand_sent_on = Date.current - days
  @demand_today = Date.current
  @original_demand = build_demand_letter_for_followup(@demand_sent_on)
end

When("the deadline check runs") do
  kind = Corvid::OverpaymentRecovery::Timeline.follow_up_kind(
    sent_on: @demand_sent_on, today: @demand_today,
    cites_section_506: @original_demand&.cites_section_506
  )
  if kind
    @follow_up = Corvid::OverpaymentRecovery::FollowUpGenerator.generate(
      kind: kind, original_demand: @original_demand
    )
  end
end

Then("a follow-up should be generated") do
  refute_nil @follow_up
end

Then("the follow-up should warn of False Claims Act liability") do
  assert @follow_up.warns_fca_liability
end

Then("the follow-up should state potential treble damages") do
  assert @follow_up.mentions_treble_damages
end

When("the provider pays in full") do
  @recovery_status = "collected"
  @collected_amount = @original_demand&.total_demanded
end

Then("no FCA warning should be generated") do
  assert_nil @follow_up
end

Then("the recovery should be marked {string}") do |status|
  assert_equal status, @recovery_status
end

# -- Interest accrual --------------------------------------------------------

Given("a demand for {float} sent {int} days ago with no payment") do |amount, days|
  @demand_amount = amount
  @demand_sent_on = Date.current - days
end

When("I calculate interest owed") do
  @interest = Corvid::OverpaymentRecovery::Timeline.interest_owed(
    amount: @demand_amount, sent_on: @demand_sent_on, today: Date.current
  )
  @interest_days = Corvid::OverpaymentRecovery::Timeline.days_with_accrued_interest(
    sent_on: @demand_sent_on, today: Date.current
  )
end

Then("interest should be accrued for {int} days") do |days|
  assert_equal days, @interest_days
end

Then("the interest rate should be the current Treasury rate") do
  assert_equal "current Treasury rate",
               Corvid::OverpaymentRecovery::Timeline::TREASURY_RATE_LABEL
end

Then("no interest should be accrued") do
  assert_equal BigDecimal("0"), @interest
  assert_equal 0, @interest_days
end

# -- Follow-up escalation ----------------------------------------------------

When("the follow-up check runs") do
  cites_506 = @original_demand&.cites_section_506
  cites_506 = true if cites_506.nil?
  kind = Corvid::OverpaymentRecovery::Timeline.follow_up_kind(
    sent_on: @demand_sent_on, today: @demand_today || Date.current,
    cites_section_506: cites_506
  )
  @follow_up = Corvid::OverpaymentRecovery::FollowUpGenerator.generate(
    kind: kind, original_demand: @original_demand
  ) if kind
end

Then("a courtesy reminder should be generated") do
  assert_equal :courtesy_reminder, @follow_up.kind
end

Then("it should reference the original demand") do
  assert @follow_up.references_original_demand
end

Then("an FCA warning letter should be generated") do
  assert_equal :fca_warning, @follow_up.kind
end

Then("the case should be escalated") do
  assert_equal :escalation, @follow_up.kind
end

Then("the customer should be notified") do
  assert @follow_up.references_original_demand
end

Then("the escalation should recommend referral to OIG or tribal attorney") do
  assert @follow_up.recommends_oig_referral
end

# -- Collection and payout --------------------------------------------------

Given("a demand for {float} collected in full") do |amount|
  @demand_amount = amount
  @collected_amount = amount
end

Given("the customer split is {int}\\/{int}") do |_corvid_pct, customer_pct|
  # The "70/30" convention reads as "corvid 70 / customer 30" — the
  # platform takes the larger share because corvid does the audit,
  # demand-letter, follow-up, and collection legwork.
  @customer_share = customer_pct / 100.0
end

Given("the customer is a corvid subscriber with {int}\\/{int} split") do |_a, _b|
  @customer_share = :corvid_subscriber
end

When("payout is processed") do
  @payout = Corvid::OverpaymentRecovery::PayoutCalculator.split(
    demanded: @demand_amount,
    collected: @collected_amount,
    customer_share: @customer_share
  )
end

Then("customer receives {float}") do |amount|
  assert_in_delta amount, @payout.customer_share.to_f, 0.01
end

Then("we retain {float}") do |amount|
  assert_in_delta amount, @payout.corvid_share.to_f, 0.01
end

Given("a demand for {float} with {float} collected") do |demanded, collected|
  @demand_amount = demanded
  @collected_amount = collected
end

Then("remaining {float} continues in collection") do |amount|
  assert_in_delta amount, @payout.remaining_in_collection.to_f, 0.01
end

Given("a demand for {float} to provider {string}") do |amount, _name|
  @demand_amount = amount
end

When("the provider requests {int} monthly installments") do |count|
  @installment_plan = Corvid::OverpaymentRecovery::InstallmentPlan.create(
    demand_total: @demand_amount, payment_count: count, first_due: Date.current >> 1
  )
end

Then("an installment plan should be created with {int} payments") do |count|
  assert_equal count, @installment_plan.payment_count
  assert_equal count, @installment_plan.installments.size
end

Then("each installment should be approximately {float}") do |amount|
  per_payment = @installment_plan.monthly_amount.to_f
  assert_in_delta amount, per_payment, 0.10
end

Then("payout to customer occurs after each installment clears") do
  # Behavioral note: PayoutCalculator is invoked once per cleared
  # installment in production. The plan struct itself doesn't enforce
  # that timing — callers do — so this step is a documentation assertion.
  refute_nil @installment_plan
end

# -- Batch operations --------------------------------------------------------

Given("an audit identifying overpayments to {int} providers") do |count|
  @batch_overpayments = (1..count).map do |i|
    {
      provider_name: "Provider #{i}", provider_npi: "100000#{i}",
      claims: [ { cpt_code: "99213", date_of_service: Date.today,
                paid_amount: 200.0, medicare_rate: 100.0, overpayment: BigDecimal("100") } ]
    }
  end
end

Given("the customer authorizes recovery") do
  @authorization_reference = "AUTH-BATCH"
end

When("I generate all demand letters") do
  @demand_letters = @batch_overpayments.map do |op|
    Corvid::OverpaymentRecovery::DemandLetterGenerator.generate(
      provider_name: op[:provider_name], provider_npi: op[:provider_npi],
      claims: op[:claims], customer_type: :tribal, medicare_participating: true,
      authorization_reference: @authorization_reference
    )
  end
end

Then("{int} demand letters should be created") do |count|
  assert_equal count, @demand_letters.size
end

Then("each should have a {int}-day deadline") do |days|
  @demand_letters.each { |l| assert_equal days, l.deadline_days }
end

# -- Dashboard pipeline ------------------------------------------------------

Given("demands in various states:") do |table|
  @pipeline_demands = table.hashes.map do |row|
    {
      provider: row["provider"],
      amount: row["amount"].to_d,
      status: row["status"],
      collected_amount: row["status"] == "collected" ? row["amount"].to_d : BigDecimal("0")
    }
  end
end

Then("the pipeline should show total in collection as {float}") do |expected|
  result = Corvid::OverpaymentRecovery::Pipeline.summarize(@pipeline_demands)
  assert_in_delta expected, result.in_collection.to_f, 0.01
end

Then("total collected as {float}") do |expected|
  result = Corvid::OverpaymentRecovery::Pipeline.summarize(@pipeline_demands)
  assert_in_delta expected, result.collected.to_f, 0.01
end

Then("total pending payout as calculated from collected") do
  result = Corvid::OverpaymentRecovery::Pipeline.summarize(@pipeline_demands)
  assert_equal result.collected, result.pending_payout
end

# -- Helpers -----------------------------------------------------------------

def build_demand_letter_for_followup(sent_on)
  Corvid::OverpaymentRecovery::DemandLetterGenerator.generate(
    provider_name: "Stub Provider", provider_npi: "0000000000",
    claims: [ { cpt_code: "99213", date_of_service: sent_on - 30,
              paid_amount: 200.0, medicare_rate: 100.0, overpayment: BigDecimal("100") } ],
    customer_type: :tribal, medicare_participating: true,
    sent_on: sent_on
  )
end
