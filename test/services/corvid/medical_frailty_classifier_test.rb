# frozen_string_literal: true

require "test_helper"

class Corvid::MedicalFrailtyClassifierTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  STATE = "XF"
  PATIENT_ID = "pt_test_001"
  AS_OF = Date.new(2026, 6, 15)
  ICD10 = "http://hl7.org/fhir/sid/icd-10-cm"
  RX_SYSTEM = "http://example.test/rxnorm"
  DISPLAY_LEAK = "DISPLAY_SHOULD_NOT_LEAK_794"
  DOSAGE_LEAK = "DOSAGE_SHOULD_NOT_LEAK_794"

  setup do
    Corvid::MedicalFrailtyCriteria.reset!
    @adapter = Corvid::Adapters::MockAdapter.new
    @classifier = Corvid::MedicalFrailtyClassifier.new(adapter: @adapter)
    register_criteria!
  end

  teardown do
    Corvid::MedicalFrailtyCriteria.reset!
  end

  test "condition match in window yields likely_frail with condition evidence" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: AS_OF, display: DISPLAY_LEAK)
      seed_empty_medications_and_claims

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :condition)
    end
  end

  test "medication match in window yields likely_frail with medication evidence" do
    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(code: "RX_TEST_001", authored_on: window_start, display: DISPLAY_LEAK)

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", window_start, :medication)
    end
  end

  test "claim line match in window yields likely_frail with claim evidence" do
    with_tenant(TENANT) do
      seed_empty_conditions_and_medications
      seed_claim_line(
        procedure_code: "hcpcs_test_a",
        serviced_date: AS_OF,
        procedure_display: DISPLAY_LEAK
      )

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :claim)
    end
  end

  test "evidence before lookback start and after as_of is ignored yielding not_indicated" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: window_start - 1)
      seed_medication(code: "RX_TEST_001", authored_on: AS_OF + 1)
      seed_claim_line(procedure_code: "HCPCS_TEST_A", serviced_date: window_start - 2)

      result = classify

      assert_not_indicated result
    end
  end

  test "evidence on window start and as_of boundaries is included" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: window_start)
      seed_medication(code: "RX_TEST_001", authored_on: AS_OF)

      result = classify

      assert_likely_frail result
      assert_evidence result,
        evidence_row("synthetic_z9981", window_start, :condition),
        evidence_row("synthetic_z9981", AS_OF, :medication)
    end
  end

  test "nil get_conditions yields unknown source_unavailable even when medication matches" do
    with_tenant(TENANT) do
      @adapter.define_singleton_method(:get_conditions) { |_pid| nil }
      seed_medication(code: "RX_TEST_001", authored_on: AS_OF)

      result = classify

      assert_unknown result, :source_unavailable
    end
  end

  test "nil get_medications yields unknown source_unavailable" do
    with_tenant(TENANT) do
      @adapter.define_singleton_method(:get_medications) { |_pid| nil }

      result = classify

      assert_unknown result, :source_unavailable
    end
  end

  test "nil list_claims yields unknown source_unavailable" do
    with_tenant(TENANT) do
      @adapter.define_singleton_method(:list_claims) { |_pid| nil }

      result = classify

      assert_unknown result, :source_unavailable
    end
  end

  test "unconfigured state yields unknown state_not_configured" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: AS_OF)

      result = classify(state_code: "ZZ")

      assert_unknown result, :state_not_configured
    end
  end

  test "entered_in_error condition and medication are not evidence" do
    with_tenant(TENANT) do
      seed_condition(
        code: "Z99.81",
        onset_date: AS_OF,
        clinical_status: "entered-in-error"
      )
      seed_medication(
        code: "RX_TEST_001",
        authored_on: AS_OF,
        status: "entered-in-error"
      )

      result = classify

      assert_not_indicated result
    end
  end

  test "condition with non icd10 code_system does not match" do
    with_tenant(TENANT) do
      seed_condition(
        code: "Z99.81",
        onset_date: AS_OF,
        code_system: "http://snomed.info/sct"
      )

      result = classify

      assert_not_indicated result
    end
  end

  test "icd10 prefix matching normalises dots and case on condition code" do
    with_tenant(TENANT) do
      prefix_state = register_prefix_state("E10")
      seed_condition(code: "e10.9", onset_date: AS_OF, code_system: ICD10)

      result = classify(state_code: prefix_state)

      assert_likely_frail result
      assert_evidence result, evidence_row("prefix_e10", AS_OF, :condition)
    end
  end

  test "undated would be match alone yields unknown undated_evidence" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: nil)

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "dated match stands when undated would be match also exists" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: AS_OF)
      seed_condition(code: "Z99.81", onset_date: nil)

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :condition)
    end
  end

  test "custom lookback_months narrows the inclusive window" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: AS_OF.prev_month(4))

      result = classify(lookback_months: 3)

      assert_not_indicated result
    end
  end

  test "all sources answered with no matches yields not_indicated" do
    with_tenant(TENANT) do
      result = classify

      assert_not_indicated result
    end
  end

  test "medication authored_on as time uses date part for window" do
    with_tenant(TENANT) do
      seed_medication(
        code: "RX_TEST_001",
        authored_on: Time.utc(2026, 6, 15, 23, 59, 0)
      )

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :medication)
    end
  end

  test "evidence sorted by date then source_type then category" do
    with_tenant(TENANT) do
      Corvid::MedicalFrailtyCriteria.reset!
      Corvid::MedicalFrailtyCriteria.register(
        STATE,
        categories: {
          cat_b: {
            icd10_prefixes: [ "Z9981" ],
            medication_codes: [],
            procedure_codes: []
          },
          cat_a: {
            icd10_prefixes: [],
            medication_codes: [ { system: RX_SYSTEM, code: "RX_TEST_001" } ],
            procedure_codes: [ "HCPCS_TEST_A" ]
          }
        }
      )

      shared_date = AS_OF
      seed_condition(code: "Z99.81", onset_date: shared_date)
      seed_medication(code: "RX_TEST_001", authored_on: shared_date)
      seed_claim_line(procedure_code: "HCPCS_TEST_A", serviced_date: shared_date)

      result = classify

      assert_evidence result,
        evidence_row("cat_a", shared_date, :claim),
        evidence_row("cat_b", shared_date, :condition),
        evidence_row("cat_a", shared_date, :medication)
    end
  end

  test "call validates patient_identifier is present" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) { classify(patient_identifier: "   ") }
    end
  end

  test "call validates as_of is a Date" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) { classify(as_of: AS_OF.to_time) }
      assert_raises(ArgumentError) { classify(as_of: AS_OF.iso8601) }
    end
  end

  test "call validates lookback_months is a positive Integer" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) { classify(lookback_months: 0) }
      assert_raises(ArgumentError) { classify(lookback_months: -1) }
      assert_raises(ArgumentError) { classify(lookback_months: 1.5) }
      assert_raises(ArgumentError) { classify(lookback_months: "12") }
    end
  end

  test "default constructor uses Corvid adapter" do
    global = Corvid.adapter
    Corvid.configure { |c| c.adapter = @adapter }

    service = Corvid::MedicalFrailtyClassifier.new
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: AS_OF)
      result = service.call(
        patient_identifier: PATIENT_ID,
        state_code: STATE,
        as_of: AS_OF
      )
      assert_equal :likely_frail, result.status
    end
  ensure
    Corvid.configure { |c| c.adapter = global }
  end

  test "explicit adapter kwarg routes reads through injected adapter" do
    recording = RecordingAdapter.new
    with_tenant(TENANT) do
      Corvid::MedicalFrailtyClassifier.new(adapter: recording).call(
        patient_identifier: PATIENT_ID,
        state_code: STATE,
        as_of: AS_OF
      )
    end

    assert_equal [ :get_conditions, :get_medications, :list_claims ], recording.calls
  end

  test "result omits phi from inspect and to_h and logs nothing sensitive" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: AS_OF, display: DISPLAY_LEAK)
      seed_medication(
        code: "RX_TEST_001",
        authored_on: AS_OF,
        display: DISPLAY_LEAK,
        dosage_text: DOSAGE_LEAK
      )
      seed_claim_line(
        procedure_code: "HCPCS_TEST_A",
        serviced_date: AS_OF,
        procedure_display: DISPLAY_LEAK
      )

      log_io = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_io)
      begin
        result = classify
      ensure
        Rails.logger = original_logger
      end

      secrets = [ PATIENT_ID, DISPLAY_LEAK, DOSAGE_LEAK, "Z99.81", "RX_TEST_001", "HCPCS_TEST_A" ]
      refute_phi_leaks(result, log_io.string, *secrets)
    end
  end

  private

  def window_start
    AS_OF.prev_month(12)
  end

  def register_criteria!
    Corvid::MedicalFrailtyCriteria.register(
      STATE,
      categories: {
        synthetic_z9981: {
          icd10_prefixes: [ "Z9981" ],
          medication_codes: [ { system: RX_SYSTEM, code: "RX_TEST_001" } ],
          procedure_codes: [ "HCPCS_TEST_A" ]
        }
      }
    )
  end

  def register_prefix_state(prefix)
    code = "XE"
    Corvid::MedicalFrailtyCriteria.register(
      code,
      categories: {
        prefix_e10: {
          icd10_prefixes: [ prefix ],
          medication_codes: [],
          procedure_codes: []
        }
      }
    )
    code
  end

  def classify(**overrides)
    params = {
      patient_identifier: PATIENT_ID,
      state_code: STATE,
      as_of: AS_OF,
      lookback_months: 12
    }.merge(overrides)
    @classifier.call(**params)
  end

  def seed_empty_conditions_and_claims
    # MockAdapter returns [] for unset stores.
  end

  def seed_empty_conditions_and_medications
    # MockAdapter returns [] for unset stores.
  end

  def seed_empty_medications_and_claims
    # MockAdapter returns [] for unset stores.
  end

  def seed_condition(code:, onset_date:, code_system: ICD10, clinical_status: "active", display: "SYNTHETIC CONDITION")
    @adapter.add_condition(
      PATIENT_ID,
      Corvid::ConditionReference.new(
        code: code,
        code_system: code_system,
        display: display,
        clinical_status: clinical_status,
        category: "problem-list-item",
        onset_date: onset_date
      )
    )
  end

  def seed_medication(code:, authored_on:, status: "active", display: "SYNTHETIC MED", dosage_text: DOSAGE_LEAK)
    @adapter.add_medication(
      PATIENT_ID,
      Corvid::MedicationReference.new(
        code: code,
        code_system: RX_SYSTEM,
        display: display,
        status: status,
        authored_on: authored_on,
        dosage_text: dosage_text
      )
    )
  end

  def seed_claim_line(procedure_code:, serviced_date:, procedure_display: "SYNTHETIC PROC")
    @adapter.add_claim_line(
      PATIENT_ID,
      Corvid::ClaimLineReference.new(
        claim_identifier: "clm_test_001",
        patient_identifier: PATIENT_ID,
        provider_identifier: "prv_test_001",
        procedure_code: procedure_code,
        procedure_display: procedure_display,
        serviced_date: serviced_date,
        billed_amount: nil,
        currency: "USD",
        sequence: 1
      )
    )
  end

  def evidence_row(category, date, source_type)
    { category: category, date: date, source_type: source_type }
  end

  def assert_likely_frail(result)
    assert result.frozen?
    assert_equal :likely_frail, result.status
    assert_nil result.reason
    assert result.evidence.frozen?
  end

  def assert_not_indicated(result)
    assert result.frozen?
    assert_equal :not_indicated, result.status
    assert_nil result.reason
    assert_empty result.evidence
  end

  def assert_unknown(result, reason)
    assert result.frozen?
    assert_equal :unknown, result.status
    assert_equal reason, result.reason
    assert result.evidence.frozen?
    assert_empty result.evidence
  end

  def assert_evidence(result, *expected)
    actual = result.evidence.map do |entry|
      {
        category: entry.category,
        date: entry.date,
        source_type: entry.source_type
      }
    end
    assert_equal expected, actual
  end

  def refute_phi_leaks(result, log_text, *secrets)
    [ result.inspect, result.to_h.to_s, log_text ].each do |text|
      secrets.each do |secret|
        refute_includes text, secret, "expected no PHI leak of #{secret.inspect}"
      end
    end
  end

  class RecordingAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def get_conditions(_patient_identifier)
      @calls << :get_conditions
      []
    end

    def get_medications(_patient_identifier)
      @calls << :get_medications
      []
    end

    def list_claims(_patient_identifier)
      @calls << :list_claims
      []
    end
  end
end
