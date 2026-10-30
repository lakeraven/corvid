# frozen_string_literal: true

require "minitest/autorun"
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

  # -- fetch_acknowledgments (#739) ------------------------------------------

  INVALID_SINCE_MESSAGE = "since must be a Time"

  def advancing_clock
    base = Time.utc(2026, 9, 1, 12, 0, 0)
    tick = 0
    lambda do
      time = base + (tick * 60)
      tick += 1
      time
    end
  end

  def client_with_advancing_clock
    Corvid::Rcm::FixtureClearinghouseClient.new(clock: advancing_clock)
  end

  def test_the_base_clearinghouse_client_does_not_implement_fetch_acknowledgments
    bare = Corvid::Rcm::ClearinghouseClient.new

    assert_raises(NotImplementedError) { bare.fetch_acknowledgments }
    assert_raises(NotImplementedError) { bare.fetch_acknowledgments(since: Time.utc(2026, 1, 1)) }
  end

  def test_fetch_acknowledgments_with_no_submissions_returns_empty
    client = client_with_advancing_clock

    assert_equal [], client.fetch_acknowledgments
    assert_equal [], client.fetch_acknowledgments(since: Time.utc(2026, 9, 1))
  end

  def test_later_acknowledgments_are_stamped_at_submit_and_fetch_does_not_advance_the_clock
    tick_count = 0
    base = Time.utc(2026, 9, 1, 12, 0, 0)
    clock = lambda do
      tick_count += 1
      base + ((tick_count - 1) * 60)
    end
    client = Corvid::Rcm::FixtureClearinghouseClient.new(clock: clock)

    client.submit_claim(Factory.claim)
    ticks_after_submit = tick_count

    client.fetch_acknowledgments
    client.fetch_acknowledgments

    assert_equal ticks_after_submit, tick_count
  end

  def test_later_acknowledgment_received_at_is_not_before_the_immediate_acknowledgment
    client = client_with_advancing_clock

    immediate = client.submit_claim(Factory.claim)
    later = client.fetch_acknowledgments.fetch(0)

    assert_operator later.received_at, :>=, immediate.received_at
    assert_operator later.received_at, :>, immediate.received_at
  end

  def test_fetch_acknowledgments_returns_one_later_acknowledgment_per_submission_in_order
    client = client_with_advancing_clock

    client.submit_claim(Factory.claim(identifier: "CLM-CLEAN-739"))
    client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))
    client.submit_claim(Factory.claim(identifier: "CLM-RJ-DELAYED-0001"))

    later = client.fetch_acknowledgments

    assert_equal 3, later.length
    assert_equal %w[CLM-CLEAN-739 CLM-RJ-0001 CLM-RJ-DELAYED-0001], later.map(&:claim_identifier)
  end

  def test_a_clean_claims_later_acknowledgment_is_accepted_on_277ca
    client = client_with_advancing_clock

    client.submit_claim(Factory.claim(identifier: "CLM-CLEAN-739"))
    later = client.fetch_acknowledgments.fetch(0)

    assert later.accepted?
    assert_equal "277CA", later.transaction_set
    assert_equal :awaiting_adjudication, later.disposition
  end

  def test_a_canned_rejections_later_acknowledgment_matches_the_immediate_rejection
    client = client_with_advancing_clock

    immediate = client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))
    later = client.fetch_acknowledgments.fetch(0)

    assert later.rejected?
    assert_equal immediate.edits, later.edits
    assert_equal immediate.reasons, later.reasons
  end

  def test_delayed_rejection_claim_is_accepted_at_submit_and_rejected_on_fetch
    client = client_with_advancing_clock

    immediate = client.submit_claim(Factory.claim(identifier: "CLM-RJ-DELAYED-0001"))
    later = client.fetch_acknowledgments.fetch(0)

    assert immediate.accepted?, "immediate acknowledgment must stay accepted at the clearinghouse"
    assert_empty immediate.edits

    assert later.rejected?
    assert_equal "277CA", later.transaction_set
    assert_equal :fix_and_resubmit, later.disposition
    refute_respond_to later, :denied?

    edit = later.edits.find { |e| e.code.to_s.strip != "" && e.description.to_s.strip != "" }
    refute_nil edit, "delayed payer 277CA rejection must carry at least one edit"
  end

  def test_a_missing_billing_npi_rejection_is_never_later_accepted
    client = client_with_advancing_clock

    immediate = client.submit_claim(Factory.claim(billing_provider_npi: nil))
    later = client.fetch_acknowledgments.fetch(0)

    assert immediate.rejected?
    assert later.rejected?
    assert_equal immediate.edits, later.edits
  end

  def test_the_same_claim_identifier_submitted_twice_yields_two_later_acknowledgments
    client = client_with_advancing_clock

    client.submit_claim(Factory.claim(identifier: "CLM-DUP-739"))
    client.submit_claim(Factory.claim(identifier: "CLM-DUP-739"))

    later = client.fetch_acknowledgments

    assert_equal 2, later.length
    assert_equal %w[CLM-DUP-739 CLM-DUP-739], later.map(&:claim_identifier)
  end

  def test_fetch_acknowledgments_since_filters_by_received_at_inclusively
    client = client_with_advancing_clock

    client.submit_claim(Factory.claim(identifier: "CLM-A-739"))
    client.submit_claim(Factory.claim(identifier: "CLM-B-739"))
    client.submit_claim(Factory.claim(identifier: "CLM-C-739"))

    all_later = client.fetch_acknowledgments
    second_received_at = all_later.fetch(1).received_at

    filtered = client.fetch_acknowledgments(since: second_received_at)

    assert_equal all_later.drop(1), filtered
    assert_empty client.fetch_acknowledgments(since: all_later.last.received_at + 1)
    assert_equal all_later, client.fetch_acknowledgments(since: nil)
  end

  def test_fetch_acknowledgments_since_rejects_non_time_values
    client = client_with_advancing_clock
    client.submit_claim(Factory.claim)

    string_error = assert_raises(ArgumentError) do
      client.fetch_acknowledgments(since: "2026-09-01")
    end
    assert_equal INVALID_SINCE_MESSAGE, string_error.message

    date_error = assert_raises(ArgumentError) do
      client.fetch_acknowledgments(since: Date.new(2026, 9, 1))
    end
    assert_equal INVALID_SINCE_MESSAGE, date_error.message
  end

  def test_fetch_acknowledgments_returns_a_fresh_array_each_call
    client = client_with_advancing_clock
    client.submit_claim(Factory.claim)

    first = client.fetch_acknowledgments
    first.clear

    second = client.fetch_acknowledgments

    refute_empty second
    refute_same first, second
  end

  def test_later_acknowledgments_use_a_distinct_trace_number_without_patient_identifiers
    client = client_with_advancing_clock
    patient_identifier = "pt_trace_redaction_739"

    immediate = client.submit_claim(Factory.claim(patient_identifier: patient_identifier))
    later = client.fetch_acknowledgments.fetch(0)

    refute_equal immediate.trace_number, later.trace_number
    refute_includes immediate.trace_number, patient_identifier
    refute_includes later.trace_number, patient_identifier
  end

  def test_fixture_later_acknowledgments_leave_raw_reference_nil
    client = client_with_advancing_clock
    client.submit_claim(Factory.claim)

    client.fetch_acknowledgments.each do |ack|
      assert_nil ack.raw_reference
    end
  end

  def test_repeated_fetch_acknowledgments_return_equal_results
    client = client_with_advancing_clock
    client.submit_claim(Factory.claim(identifier: "CLM-CLEAN-739"))
    client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))

    first = client.fetch_acknowledgments
    second = client.fetch_acknowledgments

    assert_equal first, second
  end

  def test_delayed_rejection_without_usable_edits_fails_closed_at_submit
    table = Tempfile.new([ "ack_table", ".yml" ])
    table.write(<<~YAML)
      default_outcome: accepted
      default_transaction_set: "277CA"
      rejections:
        CLM-BROKEN-DELAYED:
          delayed_rejection: true
          edits: []
    YAML
    table.close

    client = Corvid::Rcm::FixtureClearinghouseClient.new(
      acknowledgment_table: table.path,
      clock: advancing_clock
    )

    assert_raises(ArgumentError) do
      client.submit_claim(Factory.claim(identifier: "CLM-BROKEN-DELAYED"))
    end
  ensure
    table&.unlink
  end

  # -- #739 review round 1 (decided rules) -----------------------------------

  DELAYED_EDIT_MESSAGE = Corvid::Rcm::FixtureClearinghouseClient::DELAYED_REJECTION_EDIT_MESSAGE
  INVALID_CLOCK_MESSAGE = "clock must return a Time"
  MISSING_NPI_EDIT = Corvid::Rcm::FixtureClearinghouseClient::MISSING_BILLING_NPI_EDIT

  def with_acknowledgment_table(yaml_body, clock: advancing_clock)
    table = Tempfile.new([ "ack_table", ".yml" ])
    table.write(yaml_body)
    table.close
    client = Corvid::Rcm::FixtureClearinghouseClient.new(
      acknowledgment_table: table.path,
      clock: clock
    )
    yield client, table.path
  ensure
    table&.unlink
  end

  def test_delayed_rejection_with_missing_billing_npi_is_rejected_at_submit_and_on_fetch
    [ nil, "  " ].each do |billing_provider_npi|
      client = client_with_advancing_clock
      claim = Factory.claim(
        identifier: "CLM-RJ-DELAYED-0001",
        billing_provider_npi: billing_provider_npi
      )

      immediate = client.submit_claim(claim)
      later = client.fetch_acknowledgments.fetch(0)

      assert immediate.rejected?, "missing billing NPI must reject at submit even for delayed_rejection"
      assert later.rejected?
      assert_equal [ MISSING_NPI_EDIT ], immediate.edits
      assert_equal immediate.edits, later.edits
    end
  end

  def test_broken_delayed_rejection_argument_error_message_is_fixed_and_redacted
    claim_id = "CLM-BROKEN-MSG-739"
    patient_identifier = "pt_redact_in_delayed_error_739"

    with_acknowledgment_table(<<~YAML) do |client, _path|
      default_outcome: accepted
      default_transaction_set: "277CA"
      rejections:
        #{claim_id}:
          delayed_rejection: true
          edits: []
    YAML
      error = assert_raises(ArgumentError) do
        client.submit_claim(Factory.claim(identifier: claim_id, patient_identifier: patient_identifier))
      end

      assert_equal DELAYED_EDIT_MESSAGE, error.message
      refute_includes error.message, claim_id
      refute_includes error.message, patient_identifier
    end
  end

  def test_delayed_rejection_with_unusable_single_edit_raises_at_submit
    tables = {
      "CLM-DELAYED-BLANK-CODE-739" => <<~YAML,
        default_outcome: accepted
        default_transaction_set: "277CA"
        rejections:
          CLM-DELAYED-BLANK-CODE-739:
            delayed_rejection: true
            edits:
              - code: ""
                description: "Synthetic payer edit with an empty code."
      YAML
      "CLM-DELAYED-BLANK-DESC-739" => <<~YAML,
        default_outcome: accepted
        default_transaction_set: "277CA"
        rejections:
          CLM-DELAYED-BLANK-DESC-739:
            delayed_rejection: true
            edits:
              - code: "A7:1"
                description: "   "
      YAML
      "CLM-DELAYED-NO-CODE-739" => <<~YAML,
        default_outcome: accepted
        default_transaction_set: "277CA"
        rejections:
          CLM-DELAYED-NO-CODE-739:
            delayed_rejection: true
            edits:
              - description: "Synthetic edit missing a code key."
      YAML
      "CLM-DELAYED-NO-DESC-739" => <<~YAML
        default_outcome: accepted
        default_transaction_set: "277CA"
        rejections:
          CLM-DELAYED-NO-DESC-739:
            delayed_rejection: true
            edits:
              - code: "A7:1"
      YAML
    }

    tables.each do |claim_id, yaml_body|
      with_acknowledgment_table(yaml_body) do |client, _path|
        assert_raises(ArgumentError) do
          client.submit_claim(Factory.claim(identifier: claim_id))
        end
      end
    end
  end

  def test_raising_submit_leaves_submitted_empty_and_no_later_acknowledgment_for_that_claim
    claim_id = "CLM-RAISE-NO-RECORD-739"

    with_acknowledgment_table(<<~YAML) do |client, _path|
      default_outcome: accepted
      default_transaction_set: "277CA"
      rejections:
        #{claim_id}:
          delayed_rejection: true
          edits: []
    YAML
      assert_raises(ArgumentError) { client.submit_claim(Factory.claim(identifier: claim_id)) }
      assert_empty client.submitted
      assert_nil client.fetch_acknowledgments.find { |ack| ack.claim_identifier == claim_id }
    end

    canned_id = "CLM-CANNED-NO-DESC-739"

    with_acknowledgment_table(<<~YAML) do |client, _path|
      default_outcome: accepted
      default_transaction_set: "277CA"
      rejections:
        #{canned_id}:
          transaction_set: "277CA"
          edits:
            - code: "A7:1"
              level: claim
    YAML
      assert_raises(StandardError) { client.submit_claim(Factory.claim(identifier: canned_id)) }
      assert_empty client.submitted
      assert_nil client.fetch_acknowledgments.find { |ack| ack.claim_identifier == canned_id }
    end

    clock_calls = 0
    broken_clock = lambda do
      clock_calls += 1
      raise "clock stopped" if clock_calls > 1

      Time.utc(2026, 9, 1, 12, 0, 0)
    end
    client = Corvid::Rcm::FixtureClearinghouseClient.new(clock: broken_clock)

    assert_raises(RuntimeError) { client.submit_claim(Factory.claim(identifier: "CLM-CLOCK-RAISE-739")) }
    assert_empty client.submitted
    assert_nil client.fetch_acknowledgments.find { |ack| ack.claim_identifier == "CLM-CLOCK-RAISE-739" }
  end

  def test_fetched_later_acknowledgment_edits_are_frozen_and_survive_mutation_attempts
    client = client_with_advancing_clock

    client.submit_claim(Factory.claim(identifier: "CLM-RJ-DELAYED-0001"))
    ack = client.fetch_acknowledgments.fetch(0)

    assert ack.edits.frozen?
    assert_raises(FrozenError) { ack.edits.clear }

    again = client.fetch_acknowledgments.fetch(0)
    refute_empty again.edits
    assert_equal ack.edits, again.edits
  end

  def test_invalid_clock_return_value_raises_with_fixed_message_and_records_nothing
    claim_id = "CLM-BAD-CLOCK-739"

    [ nil, "2026-09-01T12:00:00Z" ].each do |bad_time|
      client = Corvid::Rcm::FixtureClearinghouseClient.new(clock: -> { bad_time })

      error = assert_raises(ArgumentError) do
        client.submit_claim(Factory.claim(identifier: claim_id))
      end
      assert_equal INVALID_CLOCK_MESSAGE, error.message
      assert_empty client.submitted
      assert_nil client.fetch_acknowledgments.find { |ack| ack.claim_identifier == claim_id }
    end
  end

  # -- #739 review round 2 (decided rules) -----------------------------------

  REJECTION_EDIT_MESSAGE =
    "rejection requires one or more edits, each with a non-blank code and description"
  INVALID_REJECTIONS_KEY_MESSAGE = "rejections keys must be strings"

  ACK_TABLE_HEADER = [
    "default_outcome: accepted\n",
    "default_transaction_set: \"277CA\"\n",
    "rejections:\n"
  ].freeze

  def acknowledgment_table_path(rejection_key, rejection_body_lines)
    table = Tempfile.new([ "ack_table", ".yml" ])
    table.write(ACK_TABLE_HEADER.join)
    table.write("  #{rejection_key}:\n")
    rejection_body_lines.each { |line| table.write(line) }
    table.close
    table.path
  end

  def load_acknowledgment_table(path)
    YAML.safe_load(File.read(path))
  end

  def with_literal_acknowledgment_table(rejection_key, rejection_body_lines, clock: advancing_clock)
    path = acknowledgment_table_path(rejection_key, rejection_body_lines)
    loaded = load_acknowledgment_table(path)
    yield loaded, path, Corvid::Rcm::FixtureClearinghouseClient.new(
      acknowledgment_table: path,
      clock: clock
    )
  ensure
    File.unlink(path) if path && File.exist?(path)
  end

  def test_any_listed_rejection_with_empty_edits_raises_at_submit_and_records_nothing
    claim_id = "CLM-R2-EMPTY-EDITS-739"
    body = [
      "    transaction_set: \"277CA\"\n",
      "    edits: []\n"
    ]

    with_literal_acknowledgment_table(claim_id, body) do |loaded, _path, client|
      assert_equal({ "transaction_set" => "277CA", "edits" => [] }, loaded.fetch("rejections").fetch(claim_id))

      error = assert_raises(ArgumentError) { client.submit_claim(Factory.claim(identifier: claim_id)) }
      assert_equal REJECTION_EDIT_MESSAGE, error.message
      assert_empty client.submitted
      assert_nil client.fetch_acknowledgments.find { |ack| ack.claim_identifier == claim_id }
    end
  end

  def test_any_listed_rejection_with_transaction_set_only_raises_at_submit_and_records_nothing
    claim_id = "CLM-R2-999-ONLY-739"
    body = [
      "    transaction_set: \"999\"\n"
    ]

    with_literal_acknowledgment_table(claim_id, body) do |loaded, _path, client|
      assert_equal({ "transaction_set" => "999" }, loaded.fetch("rejections").fetch(claim_id))

      error = assert_raises(ArgumentError) { client.submit_claim(Factory.claim(identifier: claim_id)) }
      assert_equal REJECTION_EDIT_MESSAGE, error.message
      assert_empty client.submitted
      assert_nil client.fetch_acknowledgments.find { |ack| ack.claim_identifier == claim_id }
    end
  end

  def test_any_listed_rejection_with_null_row_raises_at_submit_and_records_nothing
    claim_id = "CLM-R2-NULL-ROW-739"
    path = acknowledgment_table_path(claim_id, [])
    loaded = load_acknowledgment_table(path)
    assert_nil loaded.fetch("rejections").fetch(claim_id)

    client = Corvid::Rcm::FixtureClearinghouseClient.new(
      acknowledgment_table: path,
      clock: advancing_clock
    )

    error = assert_raises(ArgumentError) { client.submit_claim(Factory.claim(identifier: claim_id)) }
    assert_equal REJECTION_EDIT_MESSAGE, error.message
    assert_empty client.submitted
    assert_nil client.fetch_acknowledgments.find { |ack| ack.claim_identifier == claim_id }
  ensure
    File.unlink(path) if path && File.exist?(path)
  end

  def test_delayed_rejection_with_one_good_edit_and_one_blank_code_edit_raises_at_submit
    claim_id = "CLM-R2-DELAYED-MIXED-739"
    body = [
      "    delayed_rejection: true\n",
      "    edits:\n",
      "      - code: \"A7:1\"\n",
      "        description: \"Synthetic payer edit with a usable code and description.\"\n",
      "      - code: \"\"\n",
      "        description: \"Synthetic payer edit with a blank code must fail the row.\"\n"
    ]
    expected_edits = [
      {
        "code" => "A7:1",
        "description" => "Synthetic payer edit with a usable code and description."
      },
      {
        "code" => "",
        "description" => "Synthetic payer edit with a blank code must fail the row."
      }
    ]

    with_literal_acknowledgment_table(claim_id, body) do |loaded, _path, client|
      row = loaded.fetch("rejections").fetch(claim_id)
      assert_equal true, row.fetch("delayed_rejection")
      assert_equal expected_edits, row.fetch("edits")

      error = assert_raises(ArgumentError) { client.submit_claim(Factory.claim(identifier: claim_id)) }
      assert_equal DELAYED_EDIT_MESSAGE, error.message
      assert_empty client.submitted
      assert_nil client.fetch_acknowledgments.find { |ack| ack.claim_identifier == claim_id }
    end
  end

  def test_acknowledgment_table_with_integer_rejection_key_raises_at_construction
    body = [
      "    transaction_set: \"277CA\"\n",
      "    edits:\n",
      "      - code: \"SYN:INT-KEY\"\n",
      "        description: \"Synthetic rejection row keyed by an unquoted YAML number.\"\n"
    ]
    path = Tempfile.new([ "ack_table", ".yml" ])
    path.write(ACK_TABLE_HEADER.join)
    path.write("  12345:\n")
    body.each { |line| path.write(line) }
    path.close

    loaded = load_acknowledgment_table(path.path)
    assert_equal 12345, loaded.fetch("rejections").keys.first
    assert_equal(
      {
        "transaction_set" => "277CA",
        "edits" => [
          {
            "code" => "SYN:INT-KEY",
            "description" => "Synthetic rejection row keyed by an unquoted YAML number."
          }
        ]
      },
      loaded.fetch("rejections").fetch(12345)
    )

    error = assert_raises(ArgumentError) do
      Corvid::Rcm::FixtureClearinghouseClient.new(acknowledgment_table: path.path)
    end
    assert_equal INVALID_REJECTIONS_KEY_MESSAGE, error.message
    refute_includes error.message, "12345"
  ensure
    path&.unlink
  end

  def clock_a_forward_then_b_backward
    sequence = [
      Time.utc(2026, 9, 1, 12, 0, 0),
      Time.utc(2026, 9, 1, 12, 1, 0),
      Time.utc(2026, 9, 1, 11, 0, 0),
      Time.utc(2026, 9, 1, 11, 1, 0)
    ]
    index = 0
    lambda do
      reading = sequence.fetch(index)
      index += 1
      reading
    end
  end

  def test_fetch_acknowledgments_since_filters_by_received_at_not_submission_order
    client = Corvid::Rcm::FixtureClearinghouseClient.new(clock: clock_a_forward_then_b_backward)

    client.submit_claim(Factory.claim(identifier: "CLM-R2-SINCE-A-739"))
    client.submit_claim(Factory.claim(identifier: "CLM-R2-SINCE-B-739"))

    filtered = client.fetch_acknowledgments(since: Time.utc(2026, 9, 1, 12, 0, 0))

    assert_equal 1, filtered.length
    assert_equal "CLM-R2-SINCE-A-739", filtered.fetch(0).claim_identifier
    assert_equal Time.utc(2026, 9, 1, 12, 1, 0), filtered.fetch(0).received_at
  end

  def test_submitted_mutation_does_not_clear_the_clients_submission_log
    client = client_with_advancing_clock

    client.submit_claim(Factory.claim(identifier: "CLM-R2-SUB-A-739"))
    client.submit_claim(Factory.claim(identifier: "CLM-R2-SUB-B-739"))

    returned = client.submitted
    begin
      returned.clear
    rescue FrozenError
      # A frozen copy must not mutate the client's log.
    end

    assert_equal 2, client.submitted.length
    assert_equal %w[CLM-R2-SUB-A-739 CLM-R2-SUB-B-739], client.submitted.map(&:identifier)
    refute_same returned, client.submitted
  end

  def test_duplicate_claim_submissions_get_distinct_later_trace_numbers
    client = client_with_advancing_clock
    claim_id = "CLM-R2-DUP-TRACE-739"

    client.submit_claim(Factory.claim(identifier: claim_id))
    client.submit_claim(Factory.claim(identifier: claim_id))

    traces = client.fetch_acknowledgments.map(&:trace_number)

    assert_equal 2, traces.length
    refute_equal traces.fetch(0), traces.fetch(1)
  end

  # -- #739 review round 3 (decided rules) -----------------------------------

  CANNED_RJ_0001_CODE = "A7:562"
  CANNED_RJ_0001_DESCRIPTION =
    "Entity's National Provider Identifier (NPI) — the billing provider NPI is not on file with this payer."
  CANNED_DELAYED_CODE = "SYN:277CA"
  CANNED_DELAYED_DESCRIPTION =
    "Payer-level claim acknowledgment — the claim was refused on a later 277CA after the clearinghouse accepted it."

  def assert_frozen_string_rejects_in_place_mutation(string)
    assert_raises(FrozenError) { string.clear }
    assert_raises(FrozenError) { string << "x" }
  end

  def test_immediate_canned_rejection_edit_strings_are_frozen_and_survive_resubmit
    client = client_with_advancing_clock

    ack = client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))
    edit = ack.edits.first

    assert_equal CANNED_RJ_0001_CODE, edit.code
    assert_equal CANNED_RJ_0001_DESCRIPTION, edit.description
    assert_frozen_string_rejects_in_place_mutation(edit.code)
    assert_frozen_string_rejects_in_place_mutation(edit.description)

    second = client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))
    second_edit = second.edits.first

    assert_equal CANNED_RJ_0001_CODE, second_edit.code
    assert_equal CANNED_RJ_0001_DESCRIPTION, second_edit.description
    refute_empty second_edit.code.strip
    refute_empty second_edit.description.strip
  end

  def test_fetched_delayed_rejection_edit_description_is_frozen_and_survives_resubmit
    client = client_with_advancing_clock

    client.submit_claim(Factory.claim(identifier: "CLM-RJ-DELAYED-0001"))
    ack = client.fetch_acknowledgments.fetch(0)
    edit = ack.edits.first

    assert_equal CANNED_DELAYED_CODE, edit.code
    assert_equal CANNED_DELAYED_DESCRIPTION, edit.description
    assert_frozen_string_rejects_in_place_mutation(edit.description)

    client.submit_claim(Factory.claim(identifier: "CLM-RJ-DELAYED-0001"))
    later = client.fetch_acknowledgments.fetch(1)
    second_edit = later.edits.first

    assert_equal CANNED_DELAYED_CODE, second_edit.code
    assert_equal CANNED_DELAYED_DESCRIPTION, second_edit.description
    refute_empty second_edit.code.strip
    refute_empty second_edit.description.strip
  end

  def test_quoted_string_false_delayed_rejection_is_rejected_at_submit_not_delayed
    claim_id = "CLM-R3-DELAYED-FALSE-STR-739"
    body = [
      "    delayed_rejection: \"false\"\n",
      "    transaction_set: \"277CA\"\n",
      "    edits:\n",
      "      - code: \"SYN:R3-FALSE-STR\"\n",
      "        description: \"Synthetic payer edit when delayed_rejection is the string false.\"\n",
      "        level: claim\n"
    ]
    expected_row = {
      "delayed_rejection" => "false",
      "transaction_set" => "277CA",
      "edits" => [
        {
          "code" => "SYN:R3-FALSE-STR",
          "description" => "Synthetic payer edit when delayed_rejection is the string false.",
          "level" => "claim"
        }
      ]
    }

    with_literal_acknowledgment_table(claim_id, body) do |loaded, _path, client|
      assert_equal expected_row, loaded.fetch("rejections").fetch(claim_id)

      immediate = client.submit_claim(Factory.claim(identifier: claim_id))

      assert immediate.rejected?
      refute immediate.accepted?
      edit = immediate.edits.first
      assert_equal "SYN:R3-FALSE-STR", edit.code
      assert_equal expected_row.fetch("edits").fetch(0).fetch("description"), edit.description
    end
  end

  def test_yes_string_delayed_rejection_is_rejected_at_submit_not_delayed
    claim_id = "CLM-R3-DELAYED-YES-STR-739"
    body = [
      "    delayed_rejection: \"yes\"\n",
      "    transaction_set: \"277CA\"\n",
      "    edits:\n",
      "      - code: \"SYN:R3-YES-STR\"\n",
      "        description: \"Synthetic payer edit when delayed_rejection is the string yes.\"\n",
      "        level: claim\n"
    ]
    expected_row = {
      "delayed_rejection" => "yes",
      "transaction_set" => "277CA",
      "edits" => [
        {
          "code" => "SYN:R3-YES-STR",
          "description" => "Synthetic payer edit when delayed_rejection is the string yes.",
          "level" => "claim"
        }
      ]
    }

    with_literal_acknowledgment_table(claim_id, body) do |loaded, _path, client|
      assert_equal expected_row, loaded.fetch("rejections").fetch(claim_id)

      immediate = client.submit_claim(Factory.claim(identifier: claim_id))

      assert immediate.rejected?
      refute immediate.accepted?
      edit = immediate.edits.first
      assert_equal "SYN:R3-YES-STR", edit.code
      assert_equal expected_row.fetch("edits").fetch(0).fetch("description"), edit.description
    end
  end
end
