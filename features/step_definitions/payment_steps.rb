# frozen_string_literal: true

# Payment processing step definitions (ported from rpms_redux)

Given("a patient {string} has an outstanding balance of {string}") do |patient_id, amount|
  Corvid.adapter.add_patient(patient_id,
    display_name: "TEST,PAYMENT PATIENT",
    dob: Date.new(1985, 1, 1), sex: "F", ssn_last4: "9999"
  )
  @payment_patient = patient_id
  @outstanding_balance = amount.gsub("$", "").to_f
end

Given("a payment of {string} was made for patient {string}") do |amount, patient_id|
  @payment = Corvid::Payment.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: patient_id,
    amount_cents: (amount.gsub("$", "").to_f * 100).to_i,
    status: "succeeded",
    payment_identifier: "PAY_EXISTING_001",
    description: "Previous payment"
  )
end

When("I create a payment of {string} for patient {string}") do |amount, patient_id|
  @payment = Corvid::Payment.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: patient_id,
    amount_cents: (amount.gsub("$", "").to_f * 100).to_i,
    description: "Copay payment"
  )
  @payment_result = @payment.process!
end

When("I refund the payment") do
  @refund_result = @payment.refund!
end

When("I view payments for patient {string}") do |patient_id|
  @patient_payments = Corvid::Payment.for_patient(patient_id)
end

Then("the payment should be processed successfully") do
  @payment.reload
  assert %w[processing succeeded].include?(@payment.status), "Expected processing or succeeded, got #{@payment.status}"
  refute_nil @payment.payment_identifier
end

Then("the payment status should be {string}") do |status|
  @payment.reload
  assert_equal status.downcase, @payment.status
end

Then("a payment record should exist") do
  refute_nil @payment
  assert @payment.persisted?
end

Then("the payment amount should be {string}") do |amount|
  expected_cents = (amount.gsub("$", "").to_f * 100).to_i
  assert_equal expected_cents, @payment.amount_cents
end

Then("the refund should be processed successfully") do
  assert_equal "refunded", @payment.reload.status
end

Then("I should see {int} payment(s)") do |count|
  assert_equal count, @patient_payments.count
end

Then("the payment should have a reference number") do
  refute_nil @payment.payment_identifier
end
