# frozen_string_literal: true

namespace :demo do
  desc "Run the narrated GM-5 PRC happy-path demo (corvid#468): " \
       "registration -> eligibility/tribal enrollment -> referral -> obligation/budget"
  task prc: :environment do
    require "corvid/adapters/enrollment_demo_adapter"

    tenant = "tnt_broken_rock"
    facility = "fac_broken_rock"
    patient_id = "pt-demo-enrolled" # seeded by EnrollmentDemoAdapter: DEMO,ENROLLED MEMBER

    def banner(title)
      puts
      puts "=" * 78
      puts title
      puts "=" * 78
    end

    def beat(label, real:)
      tag = real ? "[REAL]" : "[MOCK]"
      puts "  #{tag} #{label}"
    end

    # Guarded authorization events return false instead of raising.
    # Say why, using resource type and status only, and let the caller stop.
    def advance_or_report_blockers(referral)
      return true if yield

      beat("authorization_blockers: #{referral.authorization_blockers.join('; ')}", real: true)
      false
    end

    banner("GM-5 · Corvid PRC demo — narrated happy path (corvid#468)")
    puts "Adapter: Corvid::Adapters::EnrollmentDemoAdapter (offline, in-process, no RPMS/AWS dependency)"
    puts "Tenant:  #{tenant}   Facility: #{facility}"

    Corvid.configure { |c| c.adapter = Corvid::Adapters::EnrollmentDemoAdapter.new }

    Corvid::TenantContext.with_tenant(tenant) do
      Corvid::TenantContext.current_facility_identifier = facility

      # Clean up any prior run so this task is safely re-runnable.
      #
      # Fulfilment reports are append-only, so the referral association
      # restricts rather than cascades and Case#destroy! would raise once a
      # referral carries any report. Reseeding a demo is the one legitimate
      # reason to discard them, so it is done here, explicitly and visibly,
      # rather than by weakening the guarantee the application relies on.
      #
      # Also remove the pre-rename enrolled patient id (exact id, this demo
      # tenant and facility only) so that Case and its referral are gone
      # before the re-seed.
      legacy_patient_id = "pt_demo_enrolled"
      old_cases = Corvid::Case.where(
        tenant_identifier: tenant,
        facility_identifier: facility,
        patient_identifier: [ patient_id, legacy_patient_id ]
      ).to_a
      old_cases.each do |old_case|
        report_ids = Corvid::ReferralFulfilmentReport
          .where(prc_referral_id: old_case.prc_referrals.select(:id))
          .pluck(:id)
        Corvid::ReferralFulfilmentReport.where(id: report_ids).delete_all if report_ids.any?
        old_case.destroy!
      end

      # ----------------------------------------------------------------
      # 1. Patient registration
      # ----------------------------------------------------------------
      banner("1. Patient registration")
      patient = Corvid.adapter.find_patient(patient_id)
      beat("Patient resolved via adapter: #{patient.display_name} (DOB #{patient.dob})", real: false)

      kase = Corvid::Case.create!(
        patient_identifier: patient_id,
        facility_identifier: facility
      )
      beat("Corvid::Case ##{kase.id} created, status=#{kase.status}", real: true)

      # ----------------------------------------------------------------
      # 2. PRC referral opened
      # ----------------------------------------------------------------
      banner("2. PRC referral opened")
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_broken_rock_demo",
        facility_identifier: facility
      )
      beat("Corvid::PrcReferral ##{referral.id} created, status=#{referral.status}", real: true)

      referral.submit!
      beat("referral.submit! -> status=#{referral.status}", real: true)

      # ----------------------------------------------------------------
      # 3. Eligibility + tribal enrollment verification
      # ----------------------------------------------------------------
      banner("3. Eligibility review + tribal enrollment verification")
      referral.begin_eligibility_review!
      beat("referral.begin_eligibility_review! -> status=#{referral.status}", real: true)
      beat("EligibilityChecklistService auto-populated from adapter " \
           "(enrollment, identity, residency)", real: false)

      checklist = referral.eligibility_checklist.reload
      Corvid::EligibilityChecklist::ITEMS.each do |item|
        mark = checklist.send(item) ? "v" : "-"
        puts "      [#{mark}] #{item}"
      end

      # Staff-entered items the adapter cannot auto-fill.
      Corvid::EligibilityChecklistService.verify_item!(
        referral, :application_complete, by: "demo_operator"
      )
      beat("application_complete verified by demo_operator (staff-entered)", real: true)

      Corvid::EligibilityChecklistService.verify_item!(
        referral, :clinical_necessity_documented, source: "referring_provider_note"
      )
      beat("clinical_necessity_documented verified from referring_provider_note", real: true)

      # Payer-of-last-resort: run the on-demand payer check and report its
      # ACTUAL outcome. check_payer_eligibility! marks insurance_verified
      # itself when it finds third-party coverage; only when it finds none
      # does staff document "no third-party coverage".
      Corvid::EligibilityChecklistService.check_payer_eligibility!(referral)
      checklist.reload
      if checklist.insurance_verified
        beat("insurance_verified: third-party coverage found on payer check " \
             "(source: #{checklist.insurance_verification_source})", real: true)
      else
        Corvid::EligibilityChecklistService.verify_item!(
          referral, :insurance_verified, source: "no_third_party_coverage_confirmed"
        )
        beat("insurance_verified: no third-party coverage found — documented " \
             "(PRC is payer of last resort)", real: true)
      end

      checklist.reload
      beat("Checklist complete: #{checklist.compliance_percentage}% " \
           "(#{checklist.missing_items.size} items missing)", real: true)

      # ----------------------------------------------------------------
      # 4. Management approval + alternate resource review
      # ----------------------------------------------------------------
      banner("4. Management approval + alternate resource review")
      referral.request_management_approval!
      beat("referral.request_management_approval! -> status=#{referral.status}", real: true)

      referral.pending_approval_by = "pr-demo-002" # DEMO,HEALTH OFFICER
      referral.approve_management!
      beat("referral.approve_management! (by pr-demo-002) -> status=#{referral.status}", real: true)

      # Synthetic current determinations. The demo does not query a payer;
      # each resource is recorded not_enrolled and fresh so the exhaustion
      # guard can pass without inventing coverage.
      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        check = referral.alternate_resource_checks.find_or_create_by!(resource_type: type)
        check.update!(
          status: "not_enrolled",
          checked_at: Time.current,
          coverage_start: nil,
          coverage_end: nil,
          renewal_date: nil
        )
      end
      referral.alternate_resource_checks.reload
      beat(
        "Seeded #{referral.alternate_resource_checks.size} alternate-resource checks (synthetic not_enrolled)",
        real: true
      )

      resources_verified = advance_or_report_blockers(referral) { referral.verify_alternate_resources! }
      beat("referral.verify_alternate_resources! -> status=#{referral.status}", real: true)

      # ----------------------------------------------------------------
      # 5. Obligation / budget check
      # ----------------------------------------------------------------
      banner("5. Obligation / budget check")
      referral.update!(estimated_cost: 8_500.00, medical_priority: 2)
      beat("Estimated cost set to $8,500.00 (below $50,000 committee-review threshold)", real: true)

      result = Corvid::BudgetAvailabilityService.check(referral)
      beat("Budget summary from adapter: remaining=$#{'%.2f' % result.remaining_budget} " \
           "of $#{'%.2f' % result.total_budget} total (#{result.fiscal_year})", real: false)
      beat("funds_available=#{result.funds_available?} " \
           "requires_committee_review=#{result.requires_committee_review?}", real: true)

      reservation = nil
      if resources_verified
        reservation = Corvid::BudgetAvailabilityService.reserve_funds_if_available(
          referral.referral_identifier, referral.estimated_cost
        )
        if reservation.success?
          beat("Funds reserved: obligation #{reservation.id} (adapter-side CHS obligation)", real: false)

          priority_assigned = advance_or_report_blockers(referral) { referral.complete_priority_assignment! }
          if priority_assigned
            beat("referral.complete_priority_assignment! -> status=#{referral.status}", real: true)
          end

          if priority_assigned && !referral.authorized?
            if advance_or_report_blockers(referral) { referral.authorize! }
              beat("referral.authorize! -> status=#{referral.status}", real: true)
            end
          end
        else
          beat("[FAILED] funds not reserved: #{reservation.message} — " \
               "authorization not attempted", real: false)
        end
      else
        beat("[FAILED] alternate resources not exhausted — funds not reserved", real: true)
      end

      # ----------------------------------------------------------------
      # Summary
      # ----------------------------------------------------------------
      banner("Summary")
      puts "  Patient:        #{patient.display_name}"
      puts "  Case:           ##{kase.id} (#{kase.status})"
      puts "  Referral:       #{referral.referral_identifier} -> #{referral.status}"
      puts "  Checklist:      #{checklist.reload.compliance_percentage}% complete"
      puts "  Estimated cost: $#{'%.2f' % referral.estimated_cost.to_d}"
      obligation = if reservation.nil?
        "not reserved"
      else
        "#{reservation.id} (#{reservation.success? ? 'reserved' : 'FAILED'})"
      end
      puts "  Obligation:     #{obligation}"
      puts
      puts "REAL (engine-native, PG-backed): Case, PrcReferral state machine, EligibilityChecklist," \
           " Determination, BudgetAvailabilityService logic, tenant scoping."
      puts "MOCKED (offline adapter, swappable for a real backend): patient identity, tribal" \
           " enrollment/identity/residency verification, CHS budget summary and obligation creation."
      puts
    end
  end
end
