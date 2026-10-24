# frozen_string_literal: true

require "minitest/autorun"
require "corvid/adapters/mock_adapter"

# Issue #674: list reads follow get_conditions/get_medications — blank patient
# identifier means unknown (nil), not an answered empty list ([]).
class Corvid::Adapters::MockAdapterListReadUnknownTest < Minitest::Test
  BLANK_PATIENT_IDENTIFIERS = [ nil, "", "   " ].freeze

  def setup
    @adapter = Corvid::Adapters::MockAdapter.new
  end

  %i[list_referrals list_claims get_care_team].each do |method_name|
    BLANK_PATIENT_IDENTIFIERS.each do |blank_id|
      define_method(:"test_#{method_name}_returns_nil_for_blank_patient_#{blank_id.inspect.tr(" ", "_")}") do
        result = @adapter.public_send(method_name, blank_id)

        assert_nil result,
                   "#{method_name}(#{blank_id.inspect}) must be nil (unknown), not []"
      end
    end
  end
end
