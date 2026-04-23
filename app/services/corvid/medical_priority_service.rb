# frozen_string_literal: true

module Corvid
  # Assigns medical priority to a PRC referral based on EHR clinical data.
  # Supports IHS 2024 (4-level) priority system ported from rpms_redux.
  class MedicalPriorityService
    PRIORITIES = { emergent: 1, urgent: 2, routine: 3 }.freeze

    # IHS 2024 priority definitions
    IHS_2024_LEVELS = {
      1 => { name: "Essential - Life/Limb Threatening", funding_score: 100 },
      2 => { name: "Necessary - Chronic/Ongoing", funding_score: 75 },
      3 => { name: "Justifiable - Preventive/Elective", funding_score: 50 },
      4 => { name: "Excluded - Not Covered", funding_score: 0 }
    }.freeze

    # Keywords for IHS 2024 priority classification
    IHS_2024_KEYWORDS = {
      1 => %w[life-threatening cardiac arrest stroke emergency emergent trauma acute severe],
      2 => %w[chronic diabetes cancer treatment management follow-up ongoing chemotherapy],
      3 => %w[preventive screening mammogram annual routine evaluation],
      4 => %w[cosmetic rhinoplasty elective not\ covered excluded]
    }.freeze

    class << self
      def assign(prc_referral)
        sr = prc_referral.service_request
        return :unknown unless sr

        priority = compute_priority(sr)
        prc_referral.update!(medical_priority: priority, priority_system: "corvid_v1")
        priority
      end

      def assess(service_request, priority_system: "ihs_2024")
        case priority_system
        when "ihs_2024"
          assess_ihs_2024(service_request)
        else
          assess_ihs_2024(service_request)
        end
      end

      private

      def compute_priority(sr)
        return PRIORITIES[:emergent] if sr.emergent?
        return PRIORITIES[:urgent] if sr.urgent?

        sr.medical_priority_level || PRIORITIES[:routine]
      end

      def assess_ihs_2024(sr)
        reason = sr.try(:reason_for_referral).to_s.downcase

        level = if sr.try(:emergent?) || reason.match?(/life.threatening|cardiac|arrest|stroke|emergency|emergent|trauma/)
                  1
                elsif reason.match?(/chronic|diabetes|cancer|treatment|management|follow.up|ongoing|chemotherapy/)
                  2
                elsif reason.match?(/cosmetic|rhinoplasty|not.covered|excluded/)
                  4
                elsif reason.match?(/preventive|screening|mammogram|annual/)
                  3
                else
                  3
                end

        keywords_matched = detect_keywords(reason, level)

        AssessmentResult.new(
          priority_level: level,
          priority_system: "ihs_2024",
          priority_name: IHS_2024_LEVELS[level][:name],
          funding_priority_score: IHS_2024_LEVELS[level][:funding_score],
          keywords_detected: keywords_matched,
          requires_clinical_review: keywords_matched.empty? && level == 3,
          reason_for_referral: reason
        )
      end

      def detect_keywords(reason, _level)
        # Only count keywords that actually influenced the classification
        IHS_2024_KEYWORDS.flat_map { |lvl, kws| kws.select { |kw| reason.include?(kw) }.map { |kw| [lvl, kw] } }
          .select { |lvl, _kw| lvl <= 2 || reason.match?(/cosmetic|rhinoplasty|not.covered|excluded/) }
          .map(&:last)
      end
    end

    # Value object returned by .assess
    class AssessmentResult
      attr_reader :priority_level, :priority_system, :priority_name,
                  :funding_priority_score, :keywords_detected,
                  :reason_for_referral

      def initialize(priority_level:, priority_system:, priority_name:, funding_priority_score:,
                     keywords_detected:, requires_clinical_review:, reason_for_referral:)
        @priority_level = priority_level
        @priority_system = priority_system
        @priority_name = priority_name
        @funding_priority_score = funding_priority_score
        @keywords_detected = keywords_detected
        @requires_clinical_review = requires_clinical_review
        @reason_for_referral = reason_for_referral
      end

      def essential? = priority_level == 1
      def necessary? = priority_level == 2
      def justifiable? = priority_level == 3
      def excluded? = priority_level == 4

      def requires_clinical_review? = @requires_clinical_review

      def to_h
        {
          priority_level: priority_level,
          priority_system: priority_system,
          priority_name: priority_name,
          funding_score: funding_priority_score,
          keywords_detected: keywords_detected,
          requires_review: requires_clinical_review?
        }
      end
    end
  end
end
