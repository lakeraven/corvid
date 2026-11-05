# frozen_string_literal: true

require "test_helper"

class Corvid::MedicalFrailtyClassifierTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  STATE = "XF"
  PATIENT_ID = "pt_test_001"
  AS_OF = Date.new(2026, 6, 15)
  ICD10 = "http://hl7.org/fhir/sid/icd-10-cm"
  RX_SYSTEM = "http://example.test/rxnorm"
  AMENDMENT_RX_SYSTEM = "http://example.test/rx"
  AMENDMENT_RX_CODE = "123"
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

  test "unreadable conditions hash element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      adapter = fixed_lists_adapter(conditions: [ { bad: true } ])
      result = classify_with(adapter)

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable conditions nil element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(fixed_lists_adapter(conditions: [ nil ]))

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable conditions string element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(fixed_lists_adapter(conditions: [ "not_a_reference" ]))

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition nil code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(conditions: [ synthetic_condition(code: nil, onset_date: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition blank code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(conditions: [ synthetic_condition(code: "   ", onset_date: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition integer code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(conditions: [ synthetic_condition(code: 794, onset_date: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition nil code_system alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [ synthetic_condition(code: "Z99.81", code_system: nil, onset_date: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition malformed icd10 code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [ synthetic_condition(code: "E1@", onset_date: AS_OF, code_system: ICD10) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medications hash element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(fixed_lists_adapter(medications: [ { bad: true } ]))

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medications nil element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(fixed_lists_adapter(medications: [ nil ]))

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medications string element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(fixed_lists_adapter(medications: [ "not_a_reference" ]))

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication nil code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(medications: [ synthetic_medication(code: nil, authored_on: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication blank code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(medications: [ synthetic_medication(code: "  ", authored_on: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication integer code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(medications: [ synthetic_medication(code: 794, authored_on: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication nil code_system alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          medications: [ synthetic_medication(code: "RX_TEST_001", code_system: nil, authored_on: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable claims hash element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(fixed_lists_adapter(claims: [ { bad: true } ]))

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable claims nil element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(fixed_lists_adapter(claims: [ nil ]))

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable claims string element alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(fixed_lists_adapter(claims: [ "not_a_reference" ]))

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable claim nil procedure_code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(claims: [ synthetic_claim_line(procedure_code: nil, serviced_date: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable claim blank procedure_code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(claims: [ synthetic_claim_line(procedure_code: "  ", serviced_date: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable claim integer procedure_code alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(claims: [ synthetic_claim_line(procedure_code: 794, serviced_date: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable claim invalid procedure token alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(claims: [ synthetic_claim_line(procedure_code: "BAD@TOKEN", serviced_date: AS_OF) ])
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable evidence alongside dated in window match yields likely_frail without unreadable in evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [
            synthetic_condition(code: "Z99.81", onset_date: AS_OF),
            { unreadable: true },
            nil
          ]
        )
      )

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :condition)
    end
  end

  test "snomed condition only is clean non match not_indicated not unreadable" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [
            synthetic_condition(
              code: "123456",
              code_system: "http://snomed.info/sct",
              onset_date: AS_OF
            )
          ]
        )
      )

      assert_not_indicated result
    end
  end

  test "entered in error condition with nil code is ignored before readability and not unreadable" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [
            synthetic_condition(
              code: nil,
              code_system: nil,
              onset_date: AS_OF,
              clinical_status: "entered-in-error"
            )
          ]
        )
      )

      assert_not_indicated result
    end
  end

  test "unreadable_evidence wins over undated_evidence when both would apply" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [
            synthetic_condition(code: "Z99.81", onset_date: nil),
            { unreadable: true }
          ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "whitespace padded icd10 condition code and code_system match in window" do
    with_tenant(TENANT) do
      prefix_state = register_prefix_state("E10")
      seed_condition(
        code: " E10.9 ",
        code_system: " #{ICD10} ",
        onset_date: AS_OF
      )

      result = classify(state_code: prefix_state)

      assert_likely_frail result
      assert_evidence result, evidence_row("prefix_e10", AS_OF, :condition)
    end
  end

  test "whitespace padded medication code and system match in window" do
    with_tenant(TENANT) do
      seed_medication(code: " RX_TEST_001 ", code_system: " #{RX_SYSTEM} ", authored_on: AS_OF)

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :medication)
    end
  end

  test "whitespace padded claim procedure_code matches in window" do
    with_tenant(TENANT) do
      seed_claim_line(procedure_code: " HCPCS_TEST_A ", serviced_date: AS_OF)

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :claim)
    end
  end

  test "whitespace padded entered in error clinical_status is ignored" do
    with_tenant(TENANT) do
      seed_condition(
        code: "Z99.81",
        onset_date: AS_OF,
        clinical_status: " entered-in-error "
      )

      result = classify

      assert_not_indicated result
    end
  end

  test "resolved condition in window still counts as likely_frail" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: AS_OF, clinical_status: "resolved")

      result = classify

      assert_likely_frail result
    end
  end

  test "inactive condition in window still counts as likely_frail" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: AS_OF, clinical_status: "inactive")

      result = classify

      assert_likely_frail result
    end
  end

  test "stopped medication in window still counts as likely_frail" do
    with_tenant(TENANT) do
      seed_medication(code: "RX_TEST_001", authored_on: AS_OF, status: "stopped")

      result = classify

      assert_likely_frail result
    end
  end

  test "completed medication in window still counts as likely_frail" do
    with_tenant(TENANT) do
      seed_medication(code: "RX_TEST_001", authored_on: AS_OF, status: "completed")

      result = classify

      assert_likely_frail result
    end
  end

  test "undated condition with dated out of window match yields unknown undated_evidence per record" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: nil)
      seed_condition(code: "Z99.81", onset_date: window_start - 1)

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "undated medication with dated out of window match yields unknown undated_evidence per record" do
    with_tenant(TENANT) do
      seed_medication(code: "RX_TEST_001", authored_on: nil)
      seed_medication(code: "RX_TEST_001", authored_on: window_start - 1)

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "undated medication alone yields unknown undated_evidence" do
    with_tenant(TENANT) do
      seed_medication(code: "RX_TEST_001", authored_on: nil)

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "undated claim with dated out of window match yields unknown undated_evidence per record" do
    with_tenant(TENANT) do
      seed_claim_line(procedure_code: "HCPCS_TEST_A", serviced_date: nil)
      seed_claim_line(procedure_code: "HCPCS_TEST_A", serviced_date: window_start - 1)

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "undated claim alone yields unknown undated_evidence" do
    with_tenant(TENANT) do
      seed_claim_line(procedure_code: "HCPCS_TEST_A", serviced_date: nil)

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "non array condition read yields unknown source_unavailable" do
    with_tenant(TENANT) do
      @adapter.define_singleton_method(:get_conditions) { |_pid| { rows: [] } }

      result = classify

      assert_unknown result, :source_unavailable
    end
  end

  test "unreadable condition blank code_system alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [ synthetic_condition(code: "Z99.81", code_system: "   ", onset_date: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition integer code_system alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [ synthetic_condition(code: "Z99.81", code_system: 794, onset_date: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication blank code_system alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          medications: [ synthetic_medication(code: "RX_TEST_001", code_system: "   ", authored_on: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication integer code_system alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          medications: [ synthetic_medication(code: "RX_TEST_001", code_system: 794, authored_on: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition code_system nbsp alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [ synthetic_condition(code: "Z99.81", code_system: "\u00A0", onset_date: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition code_system ideographic space alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [ synthetic_condition(code: "Z99.81", code_system: "\u3000", onset_date: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition code_system zero width space alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [ synthetic_condition(code: "Z99.81", code_system: "\u200B", onset_date: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication code nbsp alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          medications: [ synthetic_medication(code: "\u00A0", authored_on: AS_OF) ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication code_system ideographic space alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          medications: [
            synthetic_medication(code: "RX_TEST_001", code_system: "\u3000", authored_on: AS_OF)
          ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable snomed condition code nbsp alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [
            synthetic_condition(
              code: "\u00A0",
              code_system: "http://snomed.info/sct",
              onset_date: AS_OF
            )
          ]
        )
      )

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unicode whitespace padded icd10 condition code_system matches in window" do
    with_tenant(TENANT) do
      prefix_state = register_prefix_state("E10")
      seed_condition(code: "E10.9", code_system: "#{ICD10}\u00A0", onset_date: AS_OF)

      result = classify(state_code: prefix_state)

      assert_likely_frail result
      assert_evidence result, evidence_row("prefix_e10", AS_OF, :condition)
    end
  end

  test "unicode whitespace padded icd10 condition code matches in window" do
    with_tenant(TENANT) do
      prefix_state = register_prefix_state("E10")
      seed_condition(code: "\u00A0E10.9", onset_date: AS_OF)

      result = classify(state_code: prefix_state)

      assert_likely_frail result
      assert_evidence result, evidence_row("prefix_e10", AS_OF, :condition)
    end
  end

  test "unicode whitespace padded medication code matches in window" do
    with_tenant(TENANT) do
      seed_medication(code: "RX_TEST_001\u3000", authored_on: AS_OF)

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :medication)
    end
  end

  test "unicode whitespace padded claim procedure_code matches in window" do
    with_tenant(TENANT) do
      seed_claim_line(procedure_code: "\u00A0HCPCS_TEST_A", serviced_date: AS_OF)

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :claim)
    end
  end

  test "unicode whitespace padded entered in error clinical_status is ignored" do
    with_tenant(TENANT) do
      seed_condition(
        code: "Z99.81",
        onset_date: AS_OF,
        clinical_status: "\u00A0entered-in-error"
      )

      result = classify

      assert_not_indicated result
    end
  end

  test "unreadable condition code invalid utf8 alone yields unknown unreadable_evidence without raising" do
    with_tenant(TENANT) do
      bad_code = "E10\xFF".dup.force_encoding("UTF-8")
      result = nil
      assert_nothing_raised do
        result = classify_with(
          fixed_lists_adapter(
            conditions: [ synthetic_condition(code: bad_code, onset_date: AS_OF) ]
          )
        )
      end

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable medication code invalid utf8 alone yields unknown unreadable_evidence without raising" do
    with_tenant(TENANT) do
      bad_code = "\xFF".dup.force_encoding("UTF-8")
      result = nil
      assert_nothing_raised do
        result = classify_with(
          fixed_lists_adapter(
            medications: [ synthetic_medication(code: bad_code, authored_on: AS_OF) ]
          )
        )
      end

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition code utf16le alone yields unknown unreadable_evidence without raising" do
    with_tenant(TENANT) do
      bad_code = "E10.9".encode("UTF-16LE")
      result = nil
      assert_nothing_raised do
        result = classify_with(
          fixed_lists_adapter(
            conditions: [ synthetic_condition(code: bad_code, onset_date: AS_OF) ]
          )
        )
      end

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable condition code_system utf16le alone yields unknown unreadable_evidence without raising" do
    with_tenant(TENANT) do
      bad_system = ICD10.encode("UTF-16LE")
      result = nil
      assert_nothing_raised do
        result = classify_with(
          fixed_lists_adapter(
            conditions: [ synthetic_condition(code: "E10.9", code_system: bad_system, onset_date: AS_OF) ]
          )
        )
      end

      assert_unknown result, :unreadable_evidence
    end
  end

  test "unreadable claim procedure_code utf16le alone yields unknown unreadable_evidence without raising" do
    with_tenant(TENANT) do
      bad_code = "G0299".encode("UTF-16LE")
      result = nil
      assert_nothing_raised do
        result = classify_with(
          fixed_lists_adapter(
            claims: [ synthetic_claim_line(procedure_code: bad_code, serviced_date: AS_OF) ]
          )
        )
      end

      assert_unknown result, :unreadable_evidence
    end
  end

  test "non array medication read yields unknown source_unavailable" do
    with_tenant(TENANT) do
      @adapter.define_singleton_method(:get_medications) { |_pid| {} }

      result = classify

      assert_unknown result, :source_unavailable
    end
  end

  test "non array claim read yields unknown source_unavailable" do
    with_tenant(TENANT) do
      @adapter.define_singleton_method(:list_claims) { |_pid| {} }

      result = classify

      assert_unknown result, :source_unavailable
    end
  end

  test "twelve month window on month end as_of includes same calendar day prior year" do
    with_tenant(TENANT) do
      as_of = Date.new(2024, 6, 15)
      seed_condition(code: "Z99.81", onset_date: Date.new(2023, 6, 15))

      result = classify(as_of: as_of)

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", Date.new(2023, 6, 15), :condition)
    end
  end

  test "leap day as_of includes evidence on prior year window start day" do
    with_tenant(TENANT) do
      as_of = Date.new(2024, 2, 29)
      seed_condition(code: "Z99.81", onset_date: Date.new(2023, 2, 28))

      result = classify(as_of: as_of)

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", Date.new(2023, 2, 28), :condition)
    end
  end

  test "month end as_of includes evidence on same day one year earlier" do
    with_tenant(TENANT) do
      as_of = Date.new(2026, 3, 31)
      seed_condition(code: "Z99.81", onset_date: Date.new(2025, 3, 31))

      result = classify(as_of: as_of)

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", Date.new(2025, 3, 31), :condition)
    end
  end

  test "medication matching code with non matching system yields not_indicated" do
    with_tenant(TENANT) do
      seed_medication(
        code: "RX_TEST_001",
        code_system: "http://example.test/other",
        authored_on: AS_OF
      )

      result = classify

      assert_not_indicated result
    end
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

  # ---- Issue #794 gate round 3 spec amendment --------------------------------

  test "registry strips padded medication system so plain adapter system matches likely_frail" do
    plain_system = "http://example.test/rx"
    Corvid::MedicalFrailtyCriteria.reset!
    Corvid::MedicalFrailtyCriteria.register(
      STATE,
      categories: {
        synthetic_z9981: {
          icd10_prefixes: [],
          medication_codes: [ { system: "#{plain_system}\u00A0", code: "RX_PAD_MATCH" } ],
          procedure_codes: []
        }
      }
    )

    with_tenant(TENANT) do
      seed_medication(code: "RX_PAD_MATCH", code_system: plain_system, authored_on: AS_OF)

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :medication)
    end
  end

  test "string condition onset_date alone yields unknown undated_evidence" do
    with_tenant(TENANT) do
      seed_condition(code: "Z99.81", onset_date: "2026-06-15")
      seed_empty_medications_and_claims

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "string medication authored_on alone yields unknown undated_evidence" do
    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(code: "RX_TEST_001", authored_on: "2026-06-01")

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "string claim serviced_date alone yields unknown undated_evidence" do
    with_tenant(TENANT) do
      seed_empty_conditions_and_medications
      seed_claim_line(procedure_code: "HCPCS_TEST_A", serviced_date: "2026-06-01")

      result = classify

      assert_unknown result, :undated_evidence
    end
  end

  test "medication authored_on as time with offset uses calendar date in window" do
    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(
        code: "RX_TEST_001",
        authored_on: Time.new(2026, 6, 1, 22, 0, 0, "-05:00")
      )

      result = classify(as_of: Date.new(2026, 6, 1), lookback_months: 1)

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", Date.new(2026, 6, 1), :medication)
    end
  end

  test "medication authored_on as time with zone uses calendar date in window" do
    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      authored_on = Time.use_zone("America/Chicago") { Time.zone.local(2026, 6, 1, 22) }
      seed_medication(code: "RX_TEST_001", authored_on: authored_on)

      result = classify(as_of: Date.new(2026, 6, 1), lookback_months: 1)

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", Date.new(2026, 6, 1), :medication)
    end
  end

  test "medication authored_on as datetime uses calendar date in window" do
    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(code: "RX_TEST_001", authored_on: DateTime.new(2026, 6, 1, 10))

      result = classify(as_of: Date.new(2026, 6, 1), lookback_months: 1)

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", Date.new(2026, 6, 1), :medication)
    end
  end

  test "condition in who icd10 system does not match icd10 cm criteria" do
    with_tenant(TENANT) do
      seed_condition(
        code: "Z99.81",
        onset_date: AS_OF,
        code_system: "http://hl7.org/fhir/sid/icd-10"
      )

      result = classify

      assert_not_indicated result
    end
  end

  test "condition in uppercased icd10 cm system uri does not match" do
    with_tenant(TENANT) do
      seed_condition(
        code: "Z99.81",
        onset_date: AS_OF,
        code_system: "HTTP://HL7.ORG/FHIR/SID/ICD-10-CM"
      )

      result = classify

      assert_not_indicated result
    end
  end

  test "medication code comparison is case exact against registered code" do
    Corvid::MedicalFrailtyCriteria.reset!
    Corvid::MedicalFrailtyCriteria.register(
      STATE,
      categories: {
        synthetic_z9981: {
          icd10_prefixes: [],
          medication_codes: [ { system: RX_SYSTEM, code: "abc" } ],
          procedure_codes: []
        }
      }
    )

    with_tenant(TENANT) do
      seed_medication(code: "ABC", authored_on: AS_OF)

      result = classify

      assert_not_indicated result
    end
  end

  test "medication system comparison is case exact against registered system" do
    lower_system = "http://example.test/rxlower"
    Corvid::MedicalFrailtyCriteria.reset!
    Corvid::MedicalFrailtyCriteria.register(
      STATE,
      categories: {
        synthetic_z9981: {
          icd10_prefixes: [],
          medication_codes: [ { system: lower_system, code: "RX_CASE_SYS" } ],
          procedure_codes: []
        }
      }
    )

    with_tenant(TENANT) do
      seed_medication(
        code: "RX_CASE_SYS",
        code_system: lower_system.upcase,
        authored_on: AS_OF
      )

      result = classify

      assert_not_indicated result
    end
  end

  test "condition code shorter than registered icd10 prefix does not yield likely_frail" do
    with_tenant(TENANT) do
      prefix_state = register_prefix_state("E10")
      seed_condition(code: "E1", onset_date: AS_OF, code_system: ICD10)

      result = classify(state_code: prefix_state)

      refute_equal :likely_frail, result.status
      assert_includes [ :not_indicated, :unknown ], result.status
    end
  end

  test "adapter medication code with trailing null after cleaning alone yields unknown unreadable_evidence" do
    register_amendment_rx_criteria!

    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(
        code: "#{AMENDMENT_RX_CODE}\u0000",
        code_system: AMENDMENT_RX_SYSTEM,
        authored_on: AS_OF
      )

      result = classify

      assert_unknown result, :unreadable_evidence
    end
  end

  test "adapter medication system with trailing null after cleaning alone yields unknown unreadable_evidence" do
    register_amendment_rx_criteria!

    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(
        code: AMENDMENT_RX_CODE,
        code_system: "#{AMENDMENT_RX_SYSTEM}\u0000",
        authored_on: AS_OF
      )

      result = classify

      assert_unknown result, :unreadable_evidence
    end
  end

  test "adapter medication code with interior ascii space after cleaning alone yields unknown unreadable_evidence" do
    register_amendment_rx_criteria!

    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(
        code: "12 3",
        code_system: AMENDMENT_RX_SYSTEM,
        authored_on: AS_OF
      )

      result = classify

      assert_unknown result, :unreadable_evidence
    end
  end

  test "adapter medication code with interior nbsp after cleaning alone yields unknown unreadable_evidence" do
    register_amendment_rx_criteria!

    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(
        code: "12\u00A03",
        code_system: AMENDMENT_RX_SYSTEM,
        authored_on: AS_OF
      )

      result = classify

      assert_unknown result, :unreadable_evidence
    end
  end

  test "adapter condition code_system with trailing null after cleaning alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      prefix_state = register_prefix_state("E10")
      seed_empty_medications_and_claims
      seed_condition(
        code: "E10.9",
        onset_date: AS_OF,
        code_system: "#{ICD10}\u0000"
      )

      result = classify(state_code: prefix_state)

      assert_unknown result, :unreadable_evidence
    end
  end

  test "adapter condition code_system with interior ascii space after cleaning alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      prefix_state = register_prefix_state("E10")
      seed_empty_medications_and_claims
      seed_condition(
        code: "E10.9",
        onset_date: AS_OF,
        code_system: "#{ICD10} x"
      )

      result = classify(state_code: prefix_state)

      assert_unknown result, :unreadable_evidence
    end
  end

  test "adapter snomed condition code_system with trailing null after cleaning alone yields unknown unreadable_evidence" do
    with_tenant(TENANT) do
      seed_empty_medications_and_claims
      seed_condition(
        code: "123456",
        onset_date: AS_OF,
        code_system: "http://snomed.info/sct\u0000"
      )

      result = classify

      assert_unknown result, :unreadable_evidence
    end
  end

  test "adapter medication code with trailing tab stripped after cleaning matches in window" do
    register_amendment_rx_criteria!

    with_tenant(TENANT) do
      seed_empty_conditions_and_claims
      seed_medication(
        code: "#{AMENDMENT_RX_CODE}\t",
        code_system: AMENDMENT_RX_SYSTEM,
        authored_on: AS_OF
      )

      result = classify

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :medication)
    end
  end

  test "unreadable medication evidence alongside dated in window condition yields likely_frail" do
    Corvid::MedicalFrailtyCriteria.reset!
    Corvid::MedicalFrailtyCriteria.register(
      STATE,
      categories: {
        synthetic_z9981: {
          icd10_prefixes: [ "Z9981" ],
          medication_codes: [ { system: AMENDMENT_RX_SYSTEM, code: AMENDMENT_RX_CODE } ],
          procedure_codes: []
        }
      }
    )

    with_tenant(TENANT) do
      result = classify_with(
        fixed_lists_adapter(
          conditions: [ synthetic_condition(code: "Z99.81", onset_date: AS_OF) ],
          medications: [
            synthetic_medication(
              code: "12 3",
              code_system: AMENDMENT_RX_SYSTEM,
              authored_on: AS_OF
            )
          ]
        )
      )

      assert_likely_frail result
      assert_evidence result, evidence_row("synthetic_z9981", AS_OF, :condition)
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

  def register_amendment_rx_criteria!
    Corvid::MedicalFrailtyCriteria.reset!
    Corvid::MedicalFrailtyCriteria.register(
      STATE,
      categories: {
        synthetic_z9981: {
          icd10_prefixes: [],
          medication_codes: [ { system: AMENDMENT_RX_SYSTEM, code: AMENDMENT_RX_CODE } ],
          procedure_codes: []
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

  def classify_with(adapter, **overrides)
    params = {
      patient_identifier: PATIENT_ID,
      state_code: STATE,
      as_of: AS_OF,
      lookback_months: 12
    }.merge(overrides)
    Corvid::MedicalFrailtyClassifier.new(adapter: adapter).call(**params)
  end

  def fixed_lists_adapter(conditions: [], medications: [], claims: [])
    FixedListsAdapter.new(conditions:, medications:, claims:)
  end

  def synthetic_condition(code:, onset_date:, code_system: ICD10, clinical_status: "active", display: "SYNTHETIC CONDITION")
    Corvid::ConditionReference.new(
      code: code,
      code_system: code_system,
      display: display,
      clinical_status: clinical_status,
      category: "problem-list-item",
      onset_date: onset_date
    )
  end

  def synthetic_medication(code:, authored_on:, code_system: RX_SYSTEM, status: "active", display: "SYNTHETIC MED")
    Corvid::MedicationReference.new(
      code: code,
      code_system: code_system,
      display: display,
      status: status,
      authored_on: authored_on,
      dosage_text: DOSAGE_LEAK
    )
  end

  def synthetic_claim_line(procedure_code:, serviced_date:, procedure_display: "SYNTHETIC PROC")
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

  def seed_medication(code:, authored_on:, status: "active", display: "SYNTHETIC MED", dosage_text: DOSAGE_LEAK, code_system: RX_SYSTEM)
    @adapter.add_medication(
      PATIENT_ID,
      Corvid::MedicationReference.new(
        code: code,
        code_system: code_system,
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

  class FixedListsAdapter
    def initialize(conditions: [], medications: [], claims: [])
      @conditions = conditions
      @medications = medications
      @claims = claims
    end

    def get_conditions(_patient_identifier)
      @conditions
    end

    def get_medications(_patient_identifier)
      @medications
    end

    def list_claims(_patient_identifier)
      @claims
    end
  end
end
