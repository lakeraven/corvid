require "test_helper"

module Corvid
  # The two columns this change removes can never come back silently.
  #
  # ADR 0003 says no corvid table holds a patient name or date of birth, and
  # corvid_cases held both — opt-in, written only by a method no host called,
  # but present in the schema of a public repository, which is where anyone
  # evaluating the claim reads it first. They are gone; this is what keeps them
  # gone.
  #
  # DELIBERATELY NARROW. A broader guard — default-deny over every column that
  # can hold PHI, with a disclosed exception list — is real and is being
  # reviewed separately, because publishing a complete inventory is an
  # inventory-and-design exercise across the whole schema and it should not
  # hold up removing two columns that should never have existed. This file
  # asserts one thing and asserts it provably.
  class NoCachedPatientPhiTest < ActiveSupport::TestCase
    REMOVED_COLUMNS = %w[patient_name_cached patient_dob_cached].freeze

    def test_corvid_cases_has_no_cached_patient_phi_columns
      columns = ActiveRecord::Base.connection.columns("corvid_cases").map(&:name)

      # A scan that found no columns also finds no violations, and that is
      # indistinguishable from a clean table. Assert the lookup worked before
      # trusting what it did not find.
      assert_operator columns.length, :>=, 10,
        "read only #{columns.length} columns from corvid_cases — the lookup is broken, not the table clean"

      present = REMOVED_COLUMNS & columns
      assert_empty present,
        "corvid_cases has #{present.join(', ')} again. ADR 0003 says no corvid table stores a " \
        "patient name or date of birth; re-adding these needs a new ADR, not a migration."
    end

    def test_case_cannot_be_asked_to_cache_patient_data
      # Asked of the CLASS, not an instance: Case.new requires tenant context
      # (MissingTenantContextError), which is the multi-tenancy enforcement
      # doing its job and nothing to do with this assertion.
      refute_includes Corvid::Case.instance_methods, :cache_patient_data!,
        "Case#cache_patient_data! is back. Its only purpose was writing a patient name and " \
        "date of birth into corvid_cases."
    end

    def test_display_name_resolves_through_the_adapter_with_no_stored_fallback
      Corvid.adapter.add_patient("pt_guard", display_name: "GUARD,TEST", dob: Date.new(1979, 3, 2), sex: "F")

      with_tenant("tnt_guard_test") do
        kase = Corvid::Case.create!(patient_identifier: "pt_guard", facility_identifier: "fac_guard")
        assert_equal "GUARD,TEST", kase.display_name

        # The name came from the adapter for the duration of the call, so it
        # must appear nowhere in the persisted row.
        row = Corvid::Case.connection.select_one("SELECT * FROM corvid_cases WHERE id = #{kase.id}")
        refute row.values.any? { |v| v.to_s.include?("GUARD,TEST") },
          "a patient name reached the corvid_cases row: #{row.inspect}"
      end
    end
  end
end
