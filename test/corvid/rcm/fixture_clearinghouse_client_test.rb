# frozen_string_literal: true

require "minitest/autorun"
require "securerandom"
require "tmpdir"
require "yaml"
require "corvid"
require "corvid/rcm"
require_relative "claim_factory"

class Corvid::Rcm::FixtureClearinghouseClientTest < Minitest::Test
  Factory = Corvid::Rcm::ClaimFactory
  FIXED_CLOCK = -> { Time.utc(2026, 9, 1, 12, 0, 0) }

  def setup
    @client = Corvid::Rcm::FixtureClearinghouseClient.new(clock: FIXED_CLOCK)
  end

  # -- the interface ---------------------------------------------------------

  def test_it_implements_the_clearinghouse_client_interface
    assert_kind_of Corvid::Rcm::ClearinghouseClient, @client
  end

  def test_the_interface_itself_refuses_to_pretend_it_works
    bare = Corvid::Rcm::ClearinghouseClient.new

    assert_raises(NotImplementedError) { bare.submit_claim(Factory.claim) }
    assert_raises(NotImplementedError) { bare.fetch_remittances }
    assert_raises(NotImplementedError) { bare.search_payers("x") }
  end

  # -- submission ------------------------------------------------------------

  def test_a_clean_claim_is_acknowledged_as_accepted
    ack = @client.submit_claim(Factory.claim)

    assert ack.accepted?
    refute ack.rejected?
    assert_equal "CLM-2001", ack.claim_identifier
    assert_equal "ACK-CLM-2001", ack.trace_number
    assert_equal :awaiting_adjudication, ack.disposition
    assert_empty ack.edits
  end

  def test_an_acceptance_is_not_a_payment_decision
    ack = @client.submit_claim(Factory.claim)

    refute_respond_to ack, :denied?, "an acknowledgment must never answer a denial question"
    assert_nil ack.work_queue
  end

  def test_submission_is_deterministic
    first = @client.submit_claim(Factory.claim)
    second = Corvid::Rcm::FixtureClearinghouseClient.new(clock: FIXED_CLOCK).submit_claim(Factory.claim)

    assert_equal first, second
  end

  def test_submitted_claims_are_recorded_in_order
    @client.submit_claim(Factory.claim(identifier: "CLM-A"))
    @client.submit_claim(Factory.claim(identifier: "CLM-B"))

    assert_equal %w[CLM-A CLM-B], @client.submitted.map(&:identifier)
  end

  # -- rejection (never adjudicated, never a denial) -------------------------

  def test_a_canned_277ca_rejection_routes_to_rework_not_appeal
    ack = @client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))

    assert ack.rejected?
    assert_equal "277CA", ack.transaction_set
    assert_equal :fix_and_resubmit, ack.disposition
    assert_equal :claim_rework, ack.work_queue
    assert_match(/billing provider NPI is not on file/, ack.reasons.first)
  end

  def test_a_999_syntax_rejection_is_still_a_rejection
    ack = @client.submit_claim(Factory.claim(identifier: "CLM-RJ-0002"))

    assert ack.rejected?
    assert_equal "999", ack.transaction_set
    assert_equal :fix_and_resubmit, ack.disposition
  end

  def test_a_rejection_can_carry_several_edits
    ack = @client.submit_claim(Factory.claim(identifier: "CLM-RJ-0003"))

    assert_equal 2, ack.edits.length
    assert_equal %w[A3:21 A3:249], ack.edits.map(&:code)
  end

  def test_a_claim_with_no_billing_provider_npi_is_rejected_at_the_front_door
    ack = @client.submit_claim(Factory.claim(billing_provider_npi: nil))

    assert ack.rejected?
    assert_match(/billing provider NPI is missing/, ack.reasons.first)
  end

  def test_an_unknown_outcome_cannot_be_constructed
    assert_raises(ArgumentError) do
      Corvid::Rcm::Acknowledgment.new(claim_identifier: "X", trace_number: "Y", outcome: :denied)
    end
  end

  # -- remittances -----------------------------------------------------------

  def test_it_returns_every_scenario_in_a_stable_order
    identifiers = @client.fetch_remittances.map(&:remittance_identifier)

    assert_equal Corvid::Rcm::FixtureClearinghouseClient::SCENARIOS.length, identifiers.length
    assert_equal identifiers, @client.fetch_remittances.map(&:remittance_identifier)
  end

  def test_it_covers_every_required_phase_0_scenario
    codes = @client.fetch_remittances.flat_map { |rem| rem.claims.flat_map(&:adjustment_codes) }.uniq

    %w[CO-45 PR-1 PR-2 PR-3 CO-16 CO-18 CO-29 CO-50 CO-97 CO-197 CO-234].each do |code|
      assert_includes codes, code
    end
  end

  # Same keyword as `Corvid::Adapters::Base#fetch_remittances`, so a caller
  # written against the adapter contract is not refused with ArgumentError.
  def test_remittances_can_be_filtered_by_a_payment_date_range
    assert_empty @client.fetch_remittances(date_range: Date.new(2026, 10, 1)..Date.new(2026, 10, 31))
    refute_empty @client.fetch_remittances(date_range: Date.new(2026, 9, 1)..Date.new(2026, 9, 30))
    refute_empty @client.fetch_remittances(date_range: Date.new(2026, 9, 1)..)
  end

  def test_the_seam_takes_the_same_keyword_as_the_adapter_contract
    seam = Corvid::Rcm::ClearinghouseClient.instance_method(:fetch_remittances).parameters
    adapter = Corvid::Adapters::Base.instance_method(:fetch_remittances).parameters

    assert_equal adapter, seam
  end

  def test_a_single_scenario_can_be_fetched_by_name
    remittance = @client.remittance("denial_duplicate_co18")

    assert_equal [ "CO-18" ], remittance.claims.first.adjustment_codes
  end

  def test_an_unknown_scenario_fails_loudly
    assert_raises(ArgumentError) { @client.remittance("no_such_scenario") }
  end

  def test_the_scenario_list_can_be_narrowed
    client = Corvid::Rcm::FixtureClearinghouseClient.new(scenarios: %w[clean_full_pay], clock: FIXED_CLOCK)

    assert_equal 1, client.fetch_remittances.length
  end

  # -- the two vocabularies stay apart ---------------------------------------

  def test_a_denial_arrives_on_the_835_and_a_rejection_never_does
    denial = @client.remittance("denial_medical_necessity_co50").claims.first

    assert denial.adjudicated?
    assert denial.denied?

    rejection = @client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))
    refute_respond_to rejection, :adjudicated?
  end

  # -- payer directory search ------------------------------------------------

  TRANSACTIONS = %i[
    professional_claim
    institutional_claim
    dental_claim
    remittance
    eligibility
    claim_status
    coverage_discovery
    coordination_of_benefits
    paper_claim
  ].freeze

  COMMERCIAL_ID = "EXCOMM01"
  COMMERCIAL_NAME = "EXAMPLE COMMERCIAL PAYER"
  COMMERCIAL_ALIAS = "EXCOMM-ALT"

  MEDICAID_ID = "EXMCD01"
  MEDICAID_NAME = "EXAMPLE STATE MEDICAID"
  MEDICAID_ALIAS = "EXMCD-ALT"

  PAPER_ID = "EXPAPER01"
  PAPER_NAME = "EXAMPLE PAPER ONLY PAYER"

  UNKNOWN_ID = "EXUNKN01"
  UNKNOWN_NAME = "EXAMPLE UNKNOWN SUPPORT PAYER"

  EXPECTED_DIRECTORY_ORDER = [ COMMERCIAL_ID, MEDICAID_ID, PAPER_ID, UNKNOWN_ID ].freeze

  def payer_directory_client(payer_directory: nil)
    kwargs = { clock: FIXED_CLOCK }
    kwargs[:payer_directory] = payer_directory if payer_directory
    Corvid::Rcm::FixtureClearinghouseClient.new(**kwargs)
  end

  def setup_payer_directory_client
    @directory_client = payer_directory_client
  end

  def find_payer(results, payer_identifier)
    results.find { |entry| entry.payer_identifier == payer_identifier } ||
      flunk("missing payer #{payer_identifier.inspect} in #{results.map(&:payer_identifier).inspect}")
  end

  def test_fixture_search_payers_returns_entries_from_the_default_directory
    setup_payer_directory_client
    results = @directory_client.search_payers("example")

    assert_equal EXPECTED_DIRECTORY_ORDER, results.map(&:payer_identifier)
    results.each { |entry| assert_kind_of Corvid::Rcm::PayerDirectoryEntry, entry }
  end

  def test_commercial_payer_supports_every_transaction
    setup_payer_directory_client
    commercial = find_payer(@directory_client.search_payers(COMMERCIAL_ID), COMMERCIAL_ID)

    TRANSACTIONS.each do |transaction|
      assert commercial.supports?(transaction), "expected #{transaction} supported for #{COMMERCIAL_ID}"
    end
  end

  def test_medicaid_payer_transaction_support_and_enrollment
    setup_payer_directory_client
    medicaid = find_payer(@directory_client.search_payers(MEDICAID_ID), MEDICAID_ID)

    assert medicaid.supports?(:professional_claim)
    assert medicaid.supports?(:eligibility)
    assert medicaid.supports?(:remittance)
    assert medicaid.enrollment_required?(:remittance)
    refute medicaid.supports?(:dental_claim)
  end

  def test_paper_only_payer_supports_paper_claim_not_electronic_claims
    setup_payer_directory_client
    paper = find_payer(@directory_client.search_payers(PAPER_ID), PAPER_ID)

    assert paper.supports?(:paper_claim)
    refute paper.supports?(:professional_claim)
    refute paper.supports?(:institutional_claim)
    refute paper.supports?(:dental_claim)
  end

  def test_unknown_support_payer_treats_every_transaction_as_unsupported_requiring_enrollment
    setup_payer_directory_client
    unknown = find_payer(@directory_client.search_payers(UNKNOWN_ID), UNKNOWN_ID)

    TRANSACTIONS.each do |transaction|
      refute unknown.supports?(transaction), "expected #{transaction} unsupported for #{UNKNOWN_ID}"
      assert unknown.enrollment_required?(transaction),
             "expected enrollment required for #{transaction} on #{UNKNOWN_ID}"
    end
  end

  def test_search_by_name_substring_is_case_insensitive
    setup_payer_directory_client

    medicaid = find_payer(@directory_client.search_payers("medicaid"), MEDICAID_ID)

    assert_equal MEDICAID_NAME, medicaid.name
  end

  def test_search_by_exact_payer_identifier
    setup_payer_directory_client

    assert_equal [ COMMERCIAL_ID ],
                 @directory_client.search_payers(COMMERCIAL_ID).map(&:payer_identifier)
  end

  def test_search_by_exact_alias
    setup_payer_directory_client

    assert_equal [ COMMERCIAL_ID ],
                 @directory_client.search_payers(COMMERCIAL_ALIAS).map(&:payer_identifier)
  end

  def test_identifier_search_does_not_return_unrelated_payers
    setup_payer_directory_client

    assert_equal [ MEDICAID_ID ],
                 @directory_client.search_payers(MEDICAID_ID).map(&:payer_identifier)
  end

  def test_blank_and_nil_queries_return_empty_arrays
    setup_payer_directory_client

    [ "", "   ", nil ].each do |query|
      assert_equal [], @directory_client.search_payers(query),
                   "expected empty results for query #{query.inspect}"
    end
  end

  def test_search_with_no_match_returns_empty
    setup_payer_directory_client

    assert_empty @directory_client.search_payers("NO_SUCH_SYNTHETIC_PAYER_XYZ")
  end

  def test_search_deduplicates_when_name_and_alias_both_match
    setup_payer_directory_client

    assert_equal [ COMMERCIAL_ID ],
                 @directory_client.search_payers("excomm").map(&:payer_identifier)
  end

  def test_search_payers_accepts_an_injectable_directory_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, "payer_directory.yml")
      File.write(path, <<~YAML)
        payers:
          - payer_identifier: TMPID01
            aliases: []
            name: TMP SYNTHETIC PAYER
            as_of: 2026-01-01
            transactions:
              professional_claim:
                supported: true
                enrollment_required: false
      YAML

      client = payer_directory_client(payer_directory: path)
      results = client.search_payers("tmpid01")

      assert_equal [ "TMPID01" ], results.map(&:payer_identifier)
    end
  end

  def test_loading_directory_with_unknown_transaction_key_raises_without_echoing_file_contents
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad_transaction_key.yml")
      marker = "SECRET_MARKER_#{SecureRandom.hex(8)}"
      File.write(path, <<~YAML)
        payers:
          - payer_identifier: BAD01
            aliases: []
            name: BAD PAYER #{marker}
            as_of: 2026-01-01
            transactions:
              dentl:
                supported: true
                enrollment_required: false
      YAML

      error = assert_raises(ArgumentError) do
        payer_directory_client(payer_directory: path).search_payers("bad")
      end
      refute_includes error.message, marker
    end
  end

  def test_loading_directory_with_non_boolean_supported_value_raises_without_echoing_file_contents
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad_supported_value.yml")
      marker = "SECRET_MARKER_#{SecureRandom.hex(8)}"
      File.write(path, <<~YAML)
        payers:
          - payer_identifier: BAD02
            aliases: []
            name: BAD PAYER #{marker}
            as_of: 2026-01-01
            transactions:
              professional_claim:
                supported: "yes"
                enrollment_required: false
      YAML

      error = assert_raises(ArgumentError) do
        payer_directory_client(payer_directory: path).search_payers("bad")
      end
      refute_includes error.message, marker
    end
  end
end
