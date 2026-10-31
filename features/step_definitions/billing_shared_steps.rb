# frozen_string_literal: true

# Shared billing step definitions

Given("the billing adapter is configured") do
  record_system_of_record(
    facility_identifier: @facility,
    tenant_identifier: @tenant
  )
end

Given("I am logged in as a billing_coordinator") do
  # No auth in corvid engine — role is implicit
end

Given("Stripe is configured for payment processing") do
  # Payment processing via adapter — mock already handles it
end
