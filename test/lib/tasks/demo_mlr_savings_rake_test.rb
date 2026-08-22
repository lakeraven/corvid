# frozen_string_literal: true

require "test_helper"
require "rake"

# Headline-integrity guard for the GM-6 MLR savings demo
# (lib/tasks/demo_mlr_savings.rake, corvid#469).
#
# The methodology doc quotes an exact headline number and asserts all
# 300 claims resolve :clear / :real. But the analyzer's headline totals
# (total_medicare_equivalent / total_overpayment_known) sum ONLY the
# :clear results — a silent rate-seeding gap would drop some claims to
# :stub_estimate / :no_rate_for_year and quietly SHRINK the headline
# rather than fail loudly. This test pins the invariant so that can't
# happen unnoticed: 300 claims analyzed, every one :clear, and the three
# worked example claims match the exact math the doc publishes.
class DemoMlrSavingsRakeTest < ActiveSupport::TestCase
  setup do
    # Defines Corvid::Gm6::MlrSavingsDemo (the module lives in the .rake
    # file) and makes the demo:mlr_savings task available.
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  teardown do
    Corvid::PrcProcedureDictionary.reset!
    Corvid::PrcFacilityDictionary.reset!
  end

  test "every claim resolves :clear and the headline totals match the doc" do
    summary = nil
    out, _err = capture_io { summary = Corvid::Gm6::MlrSavingsDemo.run }

    # (a) full panel analyzed
    assert_equal 300, summary.obligations_analyzed

    # (b) every claim is :clear / :real — no silent stub/no-rate leakage
    #     that would shrink the headline. Equality (not just a floor)
    #     catches any confidence bucket other than :clear.
    assert_equal({ clear: 300 }, summary.by_confidence,
                 "a rate-seeding gap would move claims out of :clear and " \
                 "silently shrink the headline number")
    assert_in_delta 0.0, summary.total_overpayment_stub_estimate, 0.01,
                    "no dollars should come from stub_estimate results"

    # Headline totals the methodology doc publishes verbatim. If the
    # seeded rates or panel drift, these fail loudly instead of quietly
    # printing a smaller number.
    assert_in_delta 126_240.90, summary.total_paid, 0.01
    assert_in_delta 51_304.23, summary.total_medicare_equivalent, 0.01
    assert_in_delta 74_936.67, summary.total_overpayment_known, 0.01

    # (c) the three worked example claims match their documented math.
    assert_example_claim(summary, "GM6-0071", system: :pfs,
      billed: 171.34, paid: 171.34, mlr: 95.19, savings: 76.15)
    assert_example_claim(summary, "GM6-0281", system: :opps,
      billed: 836.67, paid: 836.67, mlr: 278.89, savings: 557.78)
    assert_example_claim(summary, "GM6-0299", system: :ipps,
      billed: 24_184.83, paid: 24_184.83, mlr: 6_909.95, savings: 17_274.88)

    # The demo must print the data-source honesty check and the
    # billed-charge caveat live, so the % is never quoted as if it were
    # measured from real vendor charges.
    assert_match(/data-source honesty check/i, out)
    assert_match(/clear: 300/, out)
    assert_match(/BILLED_MULTIPLIER/, out)
  end

  private

  def assert_example_claim(summary, obligation_id, system:, billed:, paid:, mlr:, savings:)
    result = summary.results.find { |r| r.obligation_id == obligation_id }
    assert result, "expected example claim #{obligation_id} in the panel"
    assert_equal system, result.payment_system, "#{obligation_id} payment_system"
    assert_equal :real, result.rate_source, "#{obligation_id} rate_source"
    assert_equal :clear, result.recovery_confidence, "#{obligation_id} recovery_confidence"
    assert_in_delta billed, result.billed_amount.to_f, 0.01, "#{obligation_id} billed"
    assert_in_delta paid, result.paid_amount.to_f, 0.01, "#{obligation_id} paid"
    assert_in_delta mlr, result.medicare_equivalent.to_f, 0.01, "#{obligation_id} MLR"
    assert_in_delta savings, result.overpayment.to_f, 0.01, "#{obligation_id} savings"
  end
end
