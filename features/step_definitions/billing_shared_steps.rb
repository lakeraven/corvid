# frozen_string_literal: true

# Shared billing step definitions

Given("the billing adapter is configured") do
  # MockAdapter already supports billing methods — nothing extra needed
end

Given("I am logged in as a billing_coordinator") do
  # No auth in corvid engine — role is implicit
end

Given("Stripe is configured for payment processing") do
  # Payment processing via adapter — mock already handles it
end
