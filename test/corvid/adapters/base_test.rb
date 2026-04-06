# frozen_string_literal: true

require "minitest/autorun"
require "corvid/adapters/base"

class Corvid::Adapters::BaseTest < Minitest::Test
  def setup
    @adapter = Corvid::Adapters::Base.new
  end

  # -- Patient ----------------------------------------------------------------

  def test_find_patient_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.find_patient("pt_test") }
  end

  def test_search_patients_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.search_patients("Doe") }
  end

  # -- Practitioner -----------------------------------------------------------

  def test_find_practitioner_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.find_practitioner("pr_test") }
  end

  def test_search_practitioners_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.search_practitioners("Smith") }
  end

  # -- Referral ---------------------------------------------------------------

  def test_find_referral_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.find_referral("rf_test") }
  end

  def test_create_referral_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.create_referral("pt_test", reason: "test") }
  end

  def test_update_referral_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.update_referral("rf_test", status: "active") }
  end

  def test_list_referrals_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.list_referrals("pt_test") }
  end

  # -- Vault: text storage and dereference ------------------------------------

  def test_store_text_raises_not_implemented
    assert_raises(NotImplementedError) do
      @adapter.store_text(case_token: "ct_test", kind: :note, text: "synthetic")
    end
  end

  def test_fetch_text_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.fetch_text("nt_test") }
  end

  def test_dereference_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.dereference("pt_test") }
  end

  def test_dereference_many_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.dereference_many([ "pt_test" ]) }
  end

  # -- Budget -----------------------------------------------------------------

  def test_get_budget_summary_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.get_budget_summary }
  end

  def test_create_obligation_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.create_obligation("rf_test", 100.00) }
  end

  # -- Site params ------------------------------------------------------------

  def test_get_site_params_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.get_site_params }
  end

  # -- Care team --------------------------------------------------------------

  def test_get_care_team_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.get_care_team("pt_test") }
  end

  # -- Eligibility ------------------------------------------------------------

  def test_verify_eligibility_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.verify_eligibility("pt_test", "medicaid") }
  end

  # -- Optional clinical reads default to empty arrays -----------------------

  def test_get_conditions_defaults_to_empty
    assert_equal [], @adapter.get_conditions("pt_test")
  end

  def test_get_medications_defaults_to_empty
    assert_equal [], @adapter.get_medications("pt_test")
  end

  def test_get_coverages_defaults_to_empty
    assert_equal [], @adapter.get_coverages("pt_test")
  end

  # -- Optional reporting reads default to empty -----------------------------

  def test_get_obligation_summary_defaults_to_empty_hash
    assert_equal({}, @adapter.get_obligation_summary)
  end

  def test_get_outstanding_obligations_defaults_to_empty_array
    assert_equal [], @adapter.get_outstanding_obligations
  end

  def test_get_obligations_defaults_to_empty_array
    assert_equal [], @adapter.get_obligations
  end
end
