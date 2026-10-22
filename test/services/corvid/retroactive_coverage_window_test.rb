# frozen_string_literal: true

require "test_helper"

class Corvid::RetroactiveCoverageWindowTest < ActiveSupport::TestCase
  TENANT = "tnt_test"

  # -- for_application: determined window ------------------------------------

  test "for_application computes earliest covered date one month before application month on XA other" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      result = for_application(application_date: Date.new(2027, 3, 15), rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: Date.new(2027, 2, 1),
        window_months: 1,
        status: "determined",
        reasons: []
      )
    end
  end

  test "for_application computes earliest covered date two months before application month on XB waiver adult" do
    with_tenant(TENANT) do
      rule_set = xb_waiver_adult_rule_set
      result = for_application(application_date: Date.new(2027, 3, 15), rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: Date.new(2027, 1, 1),
        window_months: 2,
        status: "determined",
        reasons: []
      )
    end
  end

  test "for_application computes earliest covered date three months before application month on XA expansion adult" do
    with_tenant(TENANT) do
      rule_set = xa_expansion_adult_rule_set
      result = for_application(application_date: Date.new(2027, 1, 10), rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: Date.new(2026, 10, 1),
        window_months: 3,
        status: "determined",
        reasons: []
      )
    end
  end

  test "for_application rolls back across year boundary for three month window" do
    with_tenant(TENANT) do
      rule_set = xa_expansion_adult_rule_set
      result = for_application(application_date: Date.new(2027, 2, 1), rule_set:)

      assert_equal Date.new(2026, 11, 1), result.earliest_covered_date
      assert_equal "determined", result.status
    end
  end

  test "for_application uses retroactive window months from a directly constructed MedicaidRuleSet" do
    with_tenant(TENANT) do
      rule_set = Corvid::MedicaidRuleSet.new(
        renewal_cycle_months: 12,
        retroactive_window_months: 2,
        work_requirement: "not_applicable",
        exemption_needs_confirmation: false,
        reasons: []
      )
      result = for_application(application_date: Date.new(2027, 4, 20), rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: Date.new(2027, 2, 1),
        window_months: 2,
        status: "determined",
        reasons: []
      )
    end
  end

  # -- for_application: not applied --------------------------------------------

  test "for_application returns not_applied when application date is nil" do
    with_tenant(TENANT) do
      rule_set = xa_expansion_adult_rule_set
      result = for_application(application_date: nil, rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: nil,
        window_months: 3,
        status: "not_applied",
        reasons: [ "application_not_filed" ]
      )
    end
  end

  test "for_application not_applied merges undetermined window and rule set reasons when application date is nil" do
    with_tenant(TENANT) do
      rule_set = undetermined_rule_set
      result = for_application(application_date: nil, rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: nil,
        window_months: nil,
        status: "not_applied",
        reasons: [
          "application_not_filed",
          "retroactive_window_undetermined",
          "eligibility_group_not_configured"
        ]
      )
    end
  end

  test "for_application not_applied on unconfigured state with unknown exemption reports nil window and merged reasons" do
    with_tenant(TENANT) do
      rule_set = Corvid::MedicaidRuleSetResolver.resolve(
        eligibility_group: "expansion_adult",
        state: "ZZ",
        indian_exemption: "unknown"
      )
      result = for_application(application_date: nil, rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: nil,
        window_months: nil,
        status: "not_applied",
        reasons: [
          "application_not_filed",
          "retroactive_window_undetermined",
          "state_not_configured",
          "indian_exemption_unconfirmed"
        ]
      )
    end
  end

  test "for_application not_applied reports nil window when rule set months are not a non-negative Integer" do
    with_tenant(TENANT) do
      base = {
        renewal_cycle_months: 12,
        work_requirement: "not_applicable",
        exemption_needs_confirmation: false,
        reasons: []
      }
      invalid_months = [ -2, 1.0, "3", nil ]

      invalid_months.each do |months|
        rule_set = Corvid::MedicaidRuleSet.new(
          retroactive_window_months: months,
          **base
        )
        result = for_application(application_date: nil, rule_set:)

        assert_nil result.earliest_covered_date
        assert_nil result.window_months
        assert_equal "not_applied", result.status
        assert_includes result.reasons, "application_not_filed"
        assert_includes result.reasons, "retroactive_window_undetermined"
      end
    end
  end

  test "for_application not_applied with zero retroactive window months reports window zero without undetermined reason" do
    with_tenant(TENANT) do
      rule_set = zero_retroactive_window_rule_set
      result = for_application(application_date: nil, rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: nil,
        window_months: 0,
        status: "not_applied",
        reasons: [ "application_not_filed" ]
      )
    end
  end

  # -- for_application: zero retroactive window (no retroactive coverage) ----

  test "for_application with zero window months is determined from first day of application month" do
    with_tenant(TENANT) do
      rule_set = zero_retroactive_window_rule_set
      result = for_application(application_date: Date.new(2027, 3, 15), rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: Date.new(2027, 3, 1),
        window_months: 0,
        status: "determined",
        reasons: []
      )
      refute_includes result.reasons, "retroactive_window_undetermined"
    end
  end

  test "for_application with zero window months is undetermined for negative float string or nil months" do
    with_tenant(TENANT) do
      base = {
        renewal_cycle_months: 12,
        work_requirement: "not_applicable",
        exemption_needs_confirmation: false,
        reasons: []
      }
      invalid_months = [ -1, 1.5, "0", nil ]

      invalid_months.each do |months|
        rule_set = Corvid::MedicaidRuleSet.new(retroactive_window_months: months, **base)
        result = for_application(application_date: Date.new(2027, 3, 15), rule_set:)

        assert_equal "undetermined", result.status
        assert_nil result.earliest_covered_date
        assert_nil result.window_months
        assert_includes result.reasons, "retroactive_window_undetermined"
      end
    end
  end

  test "register resolve and for_application pass zero retro_coverage_months through to determined window" do
    with_tenant(TENANT) do
      Corvid::StateMedicaidRules.register(
        "XD",
        expanded: true,
        groups: {
          other: {
            renewal_months: 12,
            retro_coverage_months: 0,
            work_requirement: false
          }
        }
      )
      rule_set = Corvid::MedicaidRuleSetResolver.resolve(
        eligibility_group: "other",
        state: "XD",
        indian_exemption: "not_eligible"
      )
      assert_equal 0, rule_set.retroactive_window_months

      result = for_application(application_date: Date.new(2027, 3, 15), rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: Date.new(2027, 3, 1),
        window_months: 0,
        status: "determined",
        reasons: []
      )
    end
  ensure
    restore_state_medicaid_rules!
  end

  test "for_application not_applied carries configured rule set reasons such as indian_exemption_unconfirmed" do
    with_tenant(TENANT) do
      rule_set = Corvid::MedicaidRuleSetResolver.resolve(
        eligibility_group: "expansion_adult",
        state: "XA",
        indian_exemption: "unknown"
      )
      result = for_application(application_date: nil, rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: nil,
        window_months: 3,
        status: "not_applied",
        reasons: [ "application_not_filed", "indian_exemption_unconfirmed" ]
      )
    end
  end

  # -- for_application: pre-H.R. 1 -------------------------------------------

  test "for_application returns undetermined when application predates H.R. 1 effective date" do
    with_tenant(TENANT) do
      rule_set = xa_expansion_adult_rule_set
      result = for_application(application_date: Date.new(2026, 12, 31), rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: nil,
        window_months: nil,
        status: "undetermined",
        reasons: [ "application_predates_hr1" ]
      )
    end
  end

  # -- for_application: undetermined rule set --------------------------------

  test "for_application returns undetermined when retroactive window months are absent on rule set" do
    with_tenant(TENANT) do
      rule_set = undetermined_rule_set
      result = for_application(application_date: Date.new(2027, 6, 1), rule_set:)

      assert_retroactive_window(
        result,
        earliest_covered_date: nil,
        window_months: nil,
        status: "undetermined",
        reasons: [ "retroactive_window_undetermined", "eligibility_group_not_configured" ]
      )
    end
  end

  test "for_application undetermined merges resolver reasons from unconfigured state" do
    with_tenant(TENANT) do
      rule_set = Corvid::MedicaidRuleSetResolver.resolve(
        eligibility_group: "expansion_adult",
        state: "ZZ",
        indian_exemption: "unknown"
      )
      result = for_application(application_date: Date.new(2027, 6, 1), rule_set:)

      assert_equal "undetermined", result.status
      assert_includes result.reasons, "retroactive_window_undetermined"
      assert_includes result.reasons, "state_not_configured"
      assert_includes result.reasons, "indian_exemption_unconfirmed"
    end
  end

  # -- for_application: rule set reasons carried -------------------------------

  test "for_application appends rule set reasons without duplicates when exemption needs confirmation" do
    with_tenant(TENANT) do
      rule_set = Corvid::MedicaidRuleSetResolver.resolve(
        eligibility_group: "expansion_adult",
        state: "XA",
        indian_exemption: "unknown"
      )
      result = for_application(application_date: Date.new(2027, 5, 1), rule_set:)

      assert_equal "determined", result.status
      assert_equal [ "indian_exemption_unconfirmed" ], result.reasons
    end
  end

  test "for_application appends rule set reasons on pre-H.R. 1 application without duplicates" do
    with_tenant(TENANT) do
      rule_set = Corvid::MedicaidRuleSetResolver.resolve(
        eligibility_group: "expansion_adult",
        state: "XA",
        indian_exemption: "unknown"
      )
      result = for_application(application_date: Date.new(2026, 6, 1), rule_set:)

      assert_equal "undetermined", result.status
      assert_equal [ "application_predates_hr1", "indian_exemption_unconfirmed" ], result.reasons
    end
  end

  # -- for_application: immutability -------------------------------------------

  test "for_application returns frozen RetroactiveWindow and frozen reasons" do
    with_tenant(TENANT) do
      result = for_application(
        application_date: Date.new(2027, 3, 1),
        rule_set: xa_other_rule_set
      )

      assert_instance_of Corvid::RetroactiveWindow, result
      assert result.frozen?
      assert result.reasons.frozen?
      result.reasons.each { |reason| assert reason.frozen? }
      assert_raises(FrozenError) { result.reasons << "mutated" }
    end
  end

  # -- covers?: determined -----------------------------------------------------

  test "covers? is true when date of service is on earliest covered date" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      application_date = Date.new(2027, 3, 15)
      dos = Date.new(2027, 2, 1)

      assert covers?(date_of_service: dos, application_date:, rule_set:)
    end
  end

  test "covers? is true when date of service is after application date" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      application_date = Date.new(2027, 3, 15)
      dos = Date.new(2027, 4, 1)

      assert covers?(date_of_service: dos, application_date:, rule_set:)
    end
  end

  test "covers? is false when determined and date of service is before earliest covered date" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      application_date = Date.new(2027, 3, 15)
      dos = Date.new(2027, 1, 31)

      refute covers?(date_of_service: dos, application_date:, rule_set:)
    end
  end

  test "covers? with zero window months is true for dates in application month and false before" do
    with_tenant(TENANT) do
      rule_set = zero_retroactive_window_rule_set
      application_date = Date.new(2027, 3, 15)

      assert covers?(date_of_service: Date.new(2027, 3, 1), application_date:, rule_set:)
      assert covers?(date_of_service: Date.new(2027, 3, 20), application_date:, rule_set:)
      refute covers?(date_of_service: Date.new(2027, 2, 28), application_date:, rule_set:)
    end
  end

  # -- covers?: not determined / not applied -----------------------------------

  test "covers? is nil when application was not filed" do
    with_tenant(TENANT) do
      rule_set = xa_expansion_adult_rule_set
      dos = Date.new(2027, 2, 1)

      assert_nil covers?(date_of_service: dos, application_date: nil, rule_set:)
    end
  end

  test "covers? is nil when retroactive window is undetermined" do
    with_tenant(TENANT) do
      rule_set = undetermined_rule_set
      dos = Date.new(2027, 2, 1)

      assert_nil covers?(
        date_of_service: dos,
        application_date: Date.new(2027, 6, 1),
        rule_set:
      )
    end
  end

  test "covers? is nil when application predates H.R. 1" do
    with_tenant(TENANT) do
      rule_set = xa_expansion_adult_rule_set
      dos = Date.new(2026, 11, 1)

      assert_nil covers?(
        date_of_service: dos,
        application_date: Date.new(2026, 12, 1),
        rule_set:
      )
    end
  end

  test "covers? never returns false for undetermined window" do
    with_tenant(TENANT) do
      rule_set = undetermined_rule_set
      dos = Date.new(2020, 1, 1)

      result = covers?(
        date_of_service: dos,
        application_date: Date.new(2027, 6, 1),
        rule_set:
      )
      refute_equal false, result
    end
  end

  # -- filing_deadline ---------------------------------------------------------

  test "filing_deadline is last day of month one month after date of service month" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      dos = Date.new(2027, 2, 10)

      assert_equal Date.new(2027, 3, 31), filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  test "filing_deadline with zero window months is end of date of service month" do
    with_tenant(TENANT) do
      rule_set = zero_retroactive_window_rule_set
      dos = Date.new(2027, 3, 20)

      assert_equal Date.new(2027, 3, 31), filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  test "filing_deadline with zero window months is nil when deadline precedes H.R. 1 effective date" do
    with_tenant(TENANT) do
      rule_set = zero_retroactive_window_rule_set
      dos = Date.new(2026, 9, 15)

      assert_nil filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  test "filing_deadline is last day of month two months after date of service month" do
    with_tenant(TENANT) do
      rule_set = xb_waiver_adult_rule_set
      dos = Date.new(2027, 2, 10)

      assert_equal Date.new(2027, 4, 30), filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  test "filing_deadline rolls forward across year boundary from December date of service" do
    with_tenant(TENANT) do
      rule_set = xb_waiver_adult_rule_set
      dos = Date.new(2026, 12, 15)

      assert_equal Date.new(2027, 2, 28), filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  test "filing_deadline uses leap year end of February when deadline falls in leap year" do
    with_tenant(TENANT) do
      rule_set = xb_waiver_adult_rule_set
      dos = Date.new(2027, 12, 1)

      assert_equal Date.new(2028, 2, 29), filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  test "filing_deadline is nil when retroactive window months are undetermined" do
    with_tenant(TENANT) do
      rule_set = undetermined_rule_set
      dos = Date.new(2027, 2, 10)

      assert_nil filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  test "filing_deadline is nil when computed deadline precedes H.R. 1 effective date" do
    with_tenant(TENANT) do
      rule_set = xa_expansion_adult_rule_set
      dos = Date.new(2026, 9, 1)

      assert_nil filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  test "filing_deadline is present when computed deadline is on or after H.R. 1 effective date" do
    with_tenant(TENANT) do
      rule_set = xa_expansion_adult_rule_set
      dos = Date.new(2026, 10, 1)

      assert_equal Date.new(2027, 1, 31), filing_deadline(date_of_service: dos, rule_set:)
    end
  end

  # -- ArgumentError: for_application ------------------------------------------

  test "for_application raises ArgumentError for invalid application_date type without echoing the value" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      [ "2027-03-15", Time.zone.now, DateTime.new(2027, 3, 15) ].each do |bad_date|
        error = assert_raises(ArgumentError) do
          for_application(application_date: bad_date, rule_set:)
        end
        refute_includes error.message, bad_date.to_s
      end
    end
  end

  test "for_application raises ArgumentError for invalid rule_set without echoing the value" do
    with_tenant(TENANT) do
      [ nil, "XA", Object.new ].each do |bad_rule_set|
        error = assert_raises(ArgumentError) do
          for_application(application_date: Date.new(2027, 3, 1), rule_set: bad_rule_set)
        end
        refute_includes error.message, bad_rule_set.to_s unless bad_rule_set.nil?
      end
    end
  end

  # -- ArgumentError: covers? --------------------------------------------------

  test "covers? raises ArgumentError when date_of_service is missing" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) do
        Corvid::RetroactiveCoverageWindow.covers?(
          application_date: Date.new(2027, 3, 1),
          rule_set: xa_other_rule_set
        )
      end
    end
  end

  test "covers? raises ArgumentError for invalid date types without echoing the value" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      application_date = Date.new(2027, 3, 15)

      [ "2027-02-01", Time.zone.now ].each do |bad_dos|
        error = assert_raises(ArgumentError) do
          covers?(date_of_service: bad_dos, application_date:, rule_set:)
        end
        refute_includes error.message, bad_dos.to_s
      end
    end
  end

  test "covers? raises ArgumentError for invalid application_date type without echoing the value" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      dos = Date.new(2027, 2, 1)

      error = assert_raises(ArgumentError) do
        covers?(date_of_service: dos, application_date: "2027-03-15", rule_set:)
      end
      refute_includes error.message, "2027-03-15"
    end
  end

  # -- ArgumentError: filing_deadline ------------------------------------------

  test "filing_deadline raises ArgumentError when date_of_service is missing" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) do
        Corvid::RetroactiveCoverageWindow.filing_deadline(rule_set: xa_other_rule_set)
      end
    end
  end

  test "filing_deadline raises ArgumentError for invalid date_of_service without echoing the value" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      error = assert_raises(ArgumentError) do
        filing_deadline(date_of_service: "2027-02-10", rule_set:)
      end
      refute_includes error.message, "2027-02-10"
    end
  end

  test "filing_deadline raises ArgumentError for invalid rule_set without echoing the value" do
    with_tenant(TENANT) do
      bad_rule_set = { retroactive_window_months: 1 }
      error = assert_raises(ArgumentError) do
        filing_deadline(date_of_service: Date.new(2027, 2, 10), rule_set: bad_rule_set)
      end
      refute_includes error.message, bad_rule_set.to_s
    end
  end

  # -- non-Gregorian calendar start (Julian): Gregorian day semantics ----------

  test "for_application treats Julian application date as its Gregorian calendar day" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      application_date = Date.new(2027, 3, 25, Date::JULIAN)

      result = for_application(application_date:, rule_set:)

      assert_equal Date.new(2027, 3, 1), result.earliest_covered_date
      refute covers?(
        date_of_service: Date.new(2027, 2, 15),
        application_date:,
        rule_set:
      )
    end
  end

  test "filing_deadline treats Julian date of service as its Gregorian calendar day" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      date_of_service = Date.new(2027, 2, 5, Date::JULIAN)

      assert_equal Date.new(2027, 3, 31), filing_deadline(date_of_service:, rule_set:)
    end
  end

  test "covers? compares Julian date of service on its Gregorian calendar day" do
    with_tenant(TENANT) do
      rule_set = xa_other_rule_set
      application_date = Date.new(2027, 3, 25, Date::JULIAN)
      date_of_service = Date.new(2027, 2, 15, Date::JULIAN)

      refute covers?(date_of_service:, application_date:, rule_set:)
    end
  end

  private

  def for_application(application_date:, rule_set:)
    Corvid::RetroactiveCoverageWindow.for_application(application_date:, rule_set:)
  end

  def covers?(date_of_service:, application_date:, rule_set:)
    Corvid::RetroactiveCoverageWindow.covers?(
      date_of_service:,
      application_date:,
      rule_set:
    )
  end

  def filing_deadline(date_of_service:, rule_set:)
    Corvid::RetroactiveCoverageWindow.filing_deadline(date_of_service:, rule_set:)
  end

  def xa_expansion_adult_rule_set
    Corvid::MedicaidRuleSetResolver.resolve(
      eligibility_group: "expansion_adult",
      state: "XA",
      indian_exemption: "not_eligible"
    )
  end

  def xa_other_rule_set
    Corvid::MedicaidRuleSetResolver.resolve(
      eligibility_group: "other",
      state: "XA",
      indian_exemption: "not_eligible"
    )
  end

  def xb_waiver_adult_rule_set
    Corvid::MedicaidRuleSetResolver.resolve(
      eligibility_group: "waiver_adult",
      state: "XB",
      indian_exemption: "not_eligible"
    )
  end

  def undetermined_rule_set
    Corvid::MedicaidRuleSetResolver.resolve(
      eligibility_group: "waiver_adult",
      state: "XA",
      indian_exemption: "not_eligible"
    )
  end

  def zero_retroactive_window_rule_set
    Corvid::MedicaidRuleSet.new(
      renewal_cycle_months: 12,
      retroactive_window_months: 0,
      work_requirement: "not_applicable",
      exemption_needs_confirmation: false,
      reasons: []
    )
  end

  def restore_state_medicaid_rules!
    Corvid::StateMedicaidRules.reset!
    load Rails.root.join("config/initializers/corvid_state_medicaid_rules.rb")
  end

  def assert_retroactive_window(result, earliest_covered_date:, window_months:, status:, reasons:)
    assert_instance_of Corvid::RetroactiveWindow, result
    if earliest_covered_date.nil?
      assert_nil result.earliest_covered_date
    else
      assert_equal earliest_covered_date, result.earliest_covered_date
    end
    if window_months.nil?
      assert_nil result.window_months
    else
      assert_equal window_months, result.window_months
    end
    assert_equal status, result.status
    assert_equal reasons, result.reasons
  end
end
