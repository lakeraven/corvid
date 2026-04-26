# frozen_string_literal: true

module Corvid
  # Assigns medical priority to a PRC referral based on EHR clinical data.
  class MedicalPriorityService
    PRIORITIES = { emergent: 1, urgent: 2, routine: 3 }.freeze

    PRIORITY_NAMES = {
      1 => "Essential/Emergent",
      2 => "Urgent/Necessary",
      3 => "Routine/Justifiable"
    }.freeze

    FUNDING_SCORES = { 1 => 100, 2 => 75, 3 => 50 }.freeze

    # Result value object for assess
    PriorityResult = Struct.new(
      :priority_level, :priority_name, :priority_system,
      :funding_priority_score, :keywords_detected, :requires_review,
      keyword_init: true
    ) do
      def essential?
        priority_level == 1
      end

      def necessary?
        priority_level == 2
      end

      alias_method :requires_clinical_review?, :requires_review

      def to_h
        {
          priority_level: priority_level,
          priority_system: priority_system,
          priority_name: priority_name,
          funding_score: funding_priority_score,
          keywords_detected: keywords_detected || [],
          requires_review: requires_review
        }
      end
    end

    class << self
      def assign(prc_referral)
        sr = prc_referral.service_request
        return :unknown unless sr

        priority = compute_priority(sr)
        prc_referral.update!(medical_priority: priority, priority_system: "corvid_v1")
        priority
      end

      def assess(service_request)
        priority = compute_priority(service_request)
        PriorityResult.new(
          priority_level: priority,
          priority_name: PRIORITY_NAMES[priority] || "Unknown",
          priority_system: "corvid_v1",
          funding_priority_score: FUNDING_SCORES[priority] || 0,
          keywords_detected: [],
          requires_review: false
        )
      end

      private

      def compute_priority(sr)
        return PRIORITIES[:emergent] if sr.emergent?
        return PRIORITIES[:urgent] if sr.urgent?

        sr.medical_priority_level || PRIORITIES[:routine]
      end
    end
  end
end
