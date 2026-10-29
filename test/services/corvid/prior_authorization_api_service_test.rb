# frozen_string_literal: true

require "test_helper"
require "corvid/adapters/enrollment_demo_adapter"

class Corvid::PriorAuthorizationApiServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_pa"
  FACILITY = "fac_pa"

  def build_fhir_claim(overrides = {})
    {
      resourceType: "Claim",
      status: "active",
      use: "preauthorization",
      patient: { reference: "Patient/pt-pa-unit-001" },
      provider: { reference: "Practitioner/pr-pa-unit-001" },
      total: { value: 2500, currency: "USD" },
      item: [ { productOrService: "MRI" } ]
    }.merge(overrides)
  end

  test "submit_from_claim creates a Case and PrcReferral in submitted status" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      response = Corvid::PriorAuthorizationApiService.submit_from_claim(build_fhir_claim)

      assert_equal "ClaimResponse", response[:resourceType]
      assert_equal "queued", response[:outcome]
      assert_equal "submitted", response[:disposition]

      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "submitted", referral.status
      assert_equal "pt-pa-unit-001", referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim scopes case lookup by facility" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = "fac_a"
      Corvid::PriorAuthorizationApiService.submit_from_claim(build_fhir_claim)

      Corvid::TenantContext.current_facility_identifier = "fac_b"
      Corvid::PriorAuthorizationApiService.submit_from_claim(build_fhir_claim)

      cases = Corvid::Case.where(patient_identifier: "pt-pa-unit-001")
      facilities = cases.pluck(:facility_identifier).sort
      assert_equal [ "fac_a", "fac_b" ], facilities,
        "expected one Case per facility for the same patient"
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "claim_response_for maps authorized status to complete/approved" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_unit_002", facility_identifier: FACILITY)
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_unit_authorized",
        facility_identifier: FACILITY,
        status: "authorized",
        authorization_number: "AUTH-UNIT-1"
      )

      response = Corvid::PriorAuthorizationApiService.claim_response_for(referral)
      assert_equal "complete", response[:outcome]
      assert_equal "approved", response[:disposition]
      assert_equal "AUTH-UNIT-1", response[:preAuthRef]
    end
  end

  test "claim_response_for includes denial reason when status is denied" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_unit_003", facility_identifier: FACILITY)
      token = Corvid.adapter.store_text(
        case_token: kase.id.to_s, kind: :reason, text: "Service not medically necessary"
      )
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_unit_denied",
        facility_identifier: FACILITY,
        status: "denied",
        deferred_reason_token: token
      )
      referral.record_determination!(
        outcome: "denied",
        decision_method: "staff_review",
        determined_by_identifier: "pr_rev_001"
      )

      response = Corvid::PriorAuthorizationApiService.claim_response_for(referral)
      assert_equal "denied", response[:disposition]
      assert response[:processNote].any? { |n| n[:text] == "Service not medically necessary" }
    end
  end

  test "claim_response_for overrides disposition to pended for flagged-for-review" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_unit_004", facility_identifier: FACILITY)
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_unit_flagged",
        facility_identifier: FACILITY,
        status: "submitted",
        flagged_for_review: true
      )

      response = Corvid::PriorAuthorizationApiService.claim_response_for(referral)
      assert_equal "pended", response[:disposition]
      assert response[:processNote].any? { |n| n[:type] == "display" },
        "expected a processNote carrying the info-request text"
    end
  end

  test "bundle_for_patient returns a searchset Bundle scoped to the patient" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_unit_005", facility_identifier: FACILITY)
      Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_b1",
        facility_identifier: FACILITY, status: "authorized")
      Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_b2",
        facility_identifier: FACILITY, status: "denied")

      other_case = Corvid::Case.create!(patient_identifier: "pt_other", facility_identifier: FACILITY)
      Corvid::PrcReferral.create!(case: other_case, referral_identifier: "rf_other",
        facility_identifier: FACILITY, status: "authorized")

      bundle = Corvid::PriorAuthorizationApiService.bundle_for_patient("pt_pa_unit_005")
      assert_equal "Bundle", bundle[:resourceType]
      assert_equal "searchset", bundle[:type]
      assert_equal 2, bundle[:entry].size
      ids = bundle[:entry].map { |e| e[:resource][:id] }.sort
      assert_equal [ "rf_b1", "rf_b2" ], ids
    end
  end

  test "covered_services returns a Bundle of ActivityDefinitions" do
    result = Corvid::PriorAuthorizationApiService.covered_services
    assert_equal "Bundle", result[:resourceType]
    assert result[:entry].all? { |e| e[:resource][:resourceType] == "ActivityDefinition" }
  end

  test "documentation_requirements_for returns a Questionnaire with required items" do
    q = Corvid::PriorAuthorizationApiService.documentation_requirements_for("MRI")
    assert_equal "Questionnaire", q[:resourceType]
    assert q[:item].any? { |i| i[:required] }
  end

  test "submit_from_claim falls back from blank CodeableConcept text to coding display" do
    claim = build_fhir_claim(
      item: [ {
        productOrService: {
          text: "",
          coding: [ { display: "TEST,PROCEDURE 001", code: "P001" } ]
        }
      } ]
    )
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "TEST,PROCEDURE 001", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim falls back from blank coding display to code" do
    claim = build_fhir_claim(
      item: [ {
        productOrService: {
          text: "   ",
          coding: [ { display: "", code: "CODE-FALLBACK" } ]
        }
      } ]
    )
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "CODE-FALLBACK", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim uses Service when productOrService is a blank string" do
    claim = build_fhir_claim(item: [ { productOrService: "   " } ])
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "Service", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim falls back from blank string-keyed CodeableConcept text to coding display" do
    claim = {
      "resourceType" => "Claim",
      "status" => "active",
      "use" => "preauthorization",
      "patient" => { "reference" => "Patient/pt-pa-str-001" },
      "provider" => { "reference" => "Practitioner/pr-pa-str-001" },
      "total" => { "value" => 2500, "currency" => "USD" },
      "item" => [ {
        "productOrService" => {
          "text" => "",
          "coding" => [ { "display" => "TEST,PROCEDURE 002", "code" => "P1" } ]
        }
      } ]
    }
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "TEST,PROCEDURE 002", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim falls back from blank string-keyed coding display to code" do
    claim = {
      "resourceType" => "Claim",
      "status" => "active",
      "use" => "preauthorization",
      "patient" => { "reference" => "Patient/pt-pa-str-002" },
      "provider" => { "reference" => "Practitioner/pr-pa-str-002" },
      "total" => { "value" => 2500, "currency" => "USD" },
      "item" => [ {
        "productOrService" => {
          "text" => "",
          "coding" => [ { "display" => "", "code" => "P1" } ]
        }
      } ]
    }
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "P1", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "claim_response_for uses decision method when vault denial text is blank" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_blank_denial", facility_identifier: FACILITY)
      token = Corvid.adapter.store_text(
        case_token: kase.id.to_s, kind: :reason, text: "   "
      )
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_blank_denial_text",
        facility_identifier: FACILITY,
        status: "denied",
        deferred_reason_token: token
      )
      referral.record_determination!(
        outcome: "denied",
        decision_method: "staff_review",
        determined_by_identifier: "pr_rev_blank"
      )

      response = Corvid::PriorAuthorizationApiService.claim_response_for(referral)
      note = response[:processNote].find { |n| n[:type] == "display" }
      assert_equal "Denied per staff_review", note[:text]
    end
  end

  test "claim_response_for reports denial reason not recorded when deferred_reason_token is blank" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_no_denial_token", facility_identifier: FACILITY)
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_no_denial_token",
        facility_identifier: FACILITY,
        status: "denied",
        deferred_reason_token: ""
      )
      referral.record_determination!(
        outcome: "denied",
        decision_method: "staff_review",
        determined_by_identifier: "pr_rev_none"
      )

      response = Corvid::PriorAuthorizationApiService.claim_response_for(referral)
      note = response[:processNote].find { |n| n[:type] == "display" }
      assert_equal "Denial reason not recorded", note[:text]
    end
  end

  test "submit_from_claim rejects Claim when patient reference id is empty" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      referral_count = Corvid::PrcReferral.count
      case_count = Corvid::Case.count

      error = assert_raises(ArgumentError) do
        Corvid::PriorAuthorizationApiService.submit_from_claim(
          build_fhir_claim(patient: { reference: "Patient/" })
        )
      end
      assert_patient_reference_error(error)
      assert_equal referral_count, Corvid::PrcReferral.count
      assert_equal case_count, Corvid::Case.count
      refute Corvid::Case.exists?(patient_identifier: "Patient")
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim rejects Claim when patient reference id is whitespace" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      referral_count = Corvid::PrcReferral.count

      error = assert_raises(ArgumentError) do
        Corvid::PriorAuthorizationApiService.submit_from_claim(
          build_fhir_claim(patient: { reference: "Patient/ " })
        )
      end
      assert_patient_reference_error(error)
      assert_equal referral_count, Corvid::PrcReferral.count
      refute Corvid::Case.exists?(patient_identifier: "Patient")
      refute Corvid::Case.exists?(patient_identifier: " ")
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim rejects Claim when patient reference is missing" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim.except(:patient)
      referral_count = Corvid::PrcReferral.count

      error = assert_raises(ArgumentError) do
        Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      end
      assert_patient_reference_error(error)
      assert_equal referral_count, Corvid::PrcReferral.count
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil requesting provider for empty practitioner reference id" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(
          patient: { reference: "Patient/pt-pa-ref-empty-pr" },
          provider: { reference: "Practitioner/" }
        )
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil requesting provider for whitespace practitioner reference id" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(
          patient: { reference: "Patient/pt-pa-ref-ws-pr" },
          provider: { reference: "Practitioner/ " }
        )
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil requesting provider when provider reference is missing" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-ref-no-pr" }
      ).except(:provider)
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim accepts versioned Patient reference for patient identifier" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(patient: { reference: "Patient/pt-pa-hist-001/_history/3" })
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "pt-pa-hist-001", referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim accepts Corvid pt_ vault token in Patient reference" do
    token = "pt_01HK8B7Z9XCQVG3F8N5K0R4MWB"
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(patient: { reference: "Patient/#{token}" })
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal token, referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim rejects Claim when patient reference has type only" do
    assert_submit_rejects_invalid_patient(patient: { reference: "Patient" })
  end

  test "submit_from_claim rejects Claim when patient reference is wrong resource type" do
    assert_submit_rejects_invalid_patient(patient: { reference: "Practitioner/pr-pa-wrong-type" })
  end

  test "submit_from_claim rejects Claim when patient reference is contained" do
    assert_submit_rejects_invalid_patient(patient: { reference: "#contained1" })
  end

  test "submit_from_claim rejects Claim when patient reference is an absolute URL" do
    assert_submit_rejects_invalid_patient(
      patient: { reference: "https://ehr.example/fhir/Patient/pt-pa-abs-001" }
    )
  end

  test "submit_from_claim rejects Claim when patient reference is a Hash" do
    assert_submit_rejects_invalid_patient(patient: { reference: { reference: "Patient/pt-pa-hash-001" } })
  end

  test "submit_from_claim rejects Claim when patient reference is an Integer" do
    assert_submit_rejects_invalid_patient(patient: { reference: 42 })
  end

  test "submit_from_claim stores requesting provider from PractitionerRole reference" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(
          patient: { reference: "Patient/pt-pa-pr-role" },
          provider: { reference: "PractitionerRole/rol-pa-001" }
        )
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "rol-pa-001", stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores requesting provider from Organization reference" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(
          patient: { reference: "Patient/pt-pa-org-pr" },
          provider: { reference: "Organization/org-pa-001" }
        )
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "org-pa-001", stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil requesting provider for contained provider reference" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(
          patient: { reference: "Patient/pt-pa-bad-pr" },
          provider: { reference: "#contained1" }
        )
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim uses Service when CodeableConcept parts are all blank" do
    claim = build_fhir_claim(
      item: [ {
        productOrService: {
          text: "",
          coding: [ { display: "  ", code: "  " } ]
        }
      } ]
    )
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "Service", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim rejects Claim when patient element is a string reference not a Hash" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      referral_count = Corvid::PrcReferral.count
      case_count = Corvid::Case.count
      claim = build_fhir_claim.merge("patient" => "Patient/pt-1")

      error = assert_raises(ArgumentError) do
        Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      end
      assert_patient_reference_error(error)
      assert_equal referral_count, Corvid::PrcReferral.count
      assert_equal case_count, Corvid::Case.count
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil provider when provider element is a string reference not a Hash" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-str-prov" },
        provider: "Practitioner/pr-pa-str-prov"
      )
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "pt-pa-str-prov", referral.case.patient_identifier
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil requesting provider when provider reference is a patient" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(
          patient: { reference: "Patient/pt-pa-patient-pr" },
          provider: { reference: "Patient/pt-pa-patient-pr" }
        )
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim rejects Claim when patient reference id violates FHIR id syntax" do
    assert_submit_rejects_invalid_patient(patient: { reference: "Patient/pt_pa_syntax" })
  end

  test "submit_from_claim creates Case and PrcReferral for MockAdapter seeded patient" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(patient: { reference: "Patient/pt-seed-001" })
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "submitted", referral.status
      assert_equal "pt-seed-001", referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim creates Case and PrcReferral for EnrollmentDemoAdapter demo enrolled patient" do
    original_adapter = Corvid.adapter
    Corvid.configure { |c| c.adapter = Corvid::Adapters::EnrollmentDemoAdapter.new }
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(patient: { reference: "Patient/pt-demo-enrolled" })
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "submitted", referral.status
      assert_equal "pt-demo-enrolled", referral.case.patient_identifier
    ensure
      Corvid.configure { |c| c.adapter = original_adapter }
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim reads patient reference from raw ActionController::Parameters" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = ActionController::Parameters.new(
        resourceType: "Claim",
        status: "active",
        use: "preauthorization",
        patient: { reference: "Patient/pt-pa-params" },
        provider: { reference: "Practitioner/pr-pa-unit-001" },
        total: { value: 2500, currency: "USD" },
        item: [ { productOrService: "MRI" } ]
      )
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "pt-pa-params", referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim reads patient reference from permitted ActionController::Parameters" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = ActionController::Parameters.new(
        resourceType: "Claim",
        status: "active",
        use: "preauthorization",
        patient: { reference: "Patient/pt-pa-params-permit" },
        provider: { reference: "Practitioner/pr-pa-unit-001" },
        total: { value: 2500, currency: "USD" },
        item: [ { productOrService: "MRI" } ]
      ).permit!
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "pt-pa-params-permit", referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim rejects Claim when symbol and string patient references differ" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      referral_count = Corvid::PrcReferral.count
      case_count = Corvid::Case.count
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-dup-a" }
      ).merge("patient" => { "reference" => "Patient/pt-pa-dup-b" })

      error = assert_raises(ArgumentError) do
        Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      end
      assert_patient_reference_error(error)
      assert_equal referral_count, Corvid::PrcReferral.count
      assert_equal case_count, Corvid::Case.count
      refute Corvid::Case.exists?(patient_identifier: "pt-pa-dup-a")
      refute Corvid::Case.exists?(patient_identifier: "pt-pa-dup-b")
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim accepts Claim when symbol and string patient references match" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-dup-same" }
      ).merge("patient" => { "reference" => "Patient/pt-pa-dup-same" })
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "pt-pa-dup-same", referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil provider when symbol and string provider references differ" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-prov-dup" },
        provider: { reference: "Practitioner/pr-pa-dup-a" }
      ).merge("provider" => { "reference" => "Practitioner/pr-pa-dup-b" })
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "pt-pa-prov-dup", referral.case.patient_identifier
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores provider when symbol and string provider references match" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-prov-same" },
        provider: { reference: "Practitioner/pr-pa-dup-same" }
      ).merge("provider" => { "reference" => "Practitioner/pr-pa-dup-same" })
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "pr-pa-dup-same", stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim rejects Claim when patient element has conflicting inner reference keys" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      referral_count = Corvid::PrcReferral.count
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-inner-a", "reference" => "Patient/pt-pa-inner-b" }
      )

      error = assert_raises(ArgumentError) do
        Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      end
      assert_patient_reference_error(error)
      refute_match(/pt-pa-inner-a/, error.message)
      refute_match(/pt-pa-inner-b/, error.message)
      assert_equal referral_count, Corvid::PrcReferral.count
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim accepts Claim when patient element repeats the same reference under both keys" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-inner-same", "reference" => "Patient/pt-pa-inner-same" }
      )
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "pt-pa-inner-same", referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil provider when provider element has conflicting inner reference keys" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-prov-inner" },
        provider: { reference: "Practitioner/pr-pa-inner-a", "reference" => "Practitioner/pr-pa-inner-b" }
      )
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "pt-pa-prov-inner", referral.case.patient_identifier
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim records MRI from raw Parameters with nested productOrService text" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = ActionController::Parameters.new(
        resourceType: "Claim",
        status: "active",
        use: "preauthorization",
        patient: { reference: "Patient/pt-pa-params-mri-text" },
        provider: { reference: "Practitioner/pr-pa-unit-001" },
        total: { value: 2500, currency: "USD" },
        item: [ { productOrService: { text: "MRI" } } ]
      )
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "MRI", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim rejects Claim when patient reference uses rf_ token on Patient" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      referral_count = Corvid::PrcReferral.count

      error = assert_raises(ArgumentError) do
        Corvid::PriorAuthorizationApiService.submit_from_claim(
          build_fhir_claim(patient: { reference: "Patient/rf_01HK8BXYZ" })
        )
      end
      assert_match(%r{relative Patient/<id> reference}i, error.message)
      assert_match(/pt_/i, error.message)
      refute_match(/pr_,.*rf_/i, error.message)
      assert_equal referral_count, Corvid::PrcReferral.count
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim stores nil requesting provider when practitioner reference uses pt_ token" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::PriorAuthorizationApiService.submit_from_claim(
        build_fhir_claim(
          patient: { reference: "Patient/pt-pa-prefix-patient" },
          provider: { reference: "Practitioner/pt_01HK8C" }
        )
      )
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "pt-pa-prefix-patient", referral.case.patient_identifier
      assert_nil stored.requesting_provider_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim records CT from plain Hash claim when item entry is ActionController::Parameters" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = build_fhir_claim(
        patient: { reference: "Patient/pt-pa-hash-params-ct" },
        item: [ ActionController::Parameters.new("productOrService" => { "text" => "CT" }) ]
      )
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "CT", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim records MRI from permitted Parameters with nested productOrService coding display" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      claim = ActionController::Parameters.new(
        resourceType: "Claim",
        status: "active",
        use: "preauthorization",
        patient: { reference: "Patient/pt-pa-params-mri-code" },
        provider: { reference: "Practitioner/pr-pa-unit-001" },
        total: { value: 2500, currency: "USD" },
        item: [ { productOrService: { coding: [ { display: "MRI" } ] } } ]
      ).permit!
      Corvid::PriorAuthorizationApiService.submit_from_claim(claim)
      referral = Corvid::PrcReferral.order(created_at: :desc).first
      stored = Corvid.adapter.find_referral(referral.referral_identifier)
      assert_equal "MRI", stored.service_requested
    ensure
      Corvid::TenantContext.reset!
    end
  end

  def assert_patient_reference_error(error)
    assert_match(%r{relative Patient/<id> reference}i, error.message)
    assert_match(/FHIR id/i, error.message)
  end

  def assert_submit_rejects_invalid_patient(patient:)
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      referral_count = Corvid::PrcReferral.count
      case_count = Corvid::Case.count

      error = assert_raises(ArgumentError) do
        Corvid::PriorAuthorizationApiService.submit_from_claim(build_fhir_claim(patient: patient))
      end
      assert_patient_reference_error(error)
      assert_equal referral_count, Corvid::PrcReferral.count
      assert_equal case_count, Corvid::Case.count
    ensure
      Corvid::TenantContext.reset!
    end
  end
end
