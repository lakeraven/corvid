# frozen_string_literal: true

module Corvid
  # Generates PRC audit compliance reports matching the FY23 finding
  # categories. Operates on EligibilityChecklist records within tenant scope.
  class PrcAuditReportService
    class << self
      # Aggregate compliance stats per checklist item.
      # Returns { total_referrals: N, item: { complete: N, total: N, percentage: F }, ... }
      def compliance_summary(tenant:, date_range: nil)
        checklists = scoped_checklists(tenant, date_range)
        total = checklists.count

        summary = { total_referrals: total }
        Corvid::EligibilityChecklist::ITEMS.each do |item|
          complete = checklists.where(item => true).count
          summary[item] = {
            complete: complete,
            total: total,
            percentage: total > 0 ? (complete.to_f / total * 100).round(1) : 0.0
          }
        end
        summary
      end

      # Returns referrals with any missing checklist items.
      # Each entry: { referral_identifier: str, missing_items: [sym] }
      def deficiency_report(tenant:, date_range: nil)
        checklists = scoped_checklists(tenant, date_range)
          .includes(:prc_referral)

        checklists.filter_map do |checklist|
          missing = checklist.missing_items
          next if missing.empty?

          {
            referral_identifier: checklist.prc_referral.referral_identifier,
            missing_items: missing,
            compliance_percentage: checklist.compliance_percentage
          }
        end
      end

      # Simulates an auditor pulling a random sample and scoring each
      # against the 7 documentation categories.
      # Returns { item: { passed: N, sampled: N, percentage: F }, ... }
      def sample_audit(tenant:, sample_size: 60, date_range: nil)
        checklists = scoped_checklists(tenant, date_range).order(Arel.sql("RANDOM()")).limit(sample_size)
        sampled = checklists.to_a
        count = sampled.size

        result = {}
        Corvid::EligibilityChecklist::ITEMS.each do |item|
          passed = sampled.count { |c| c.send(item) }
          result[item] = {
            passed: passed,
            sampled: count,
            percentage: count > 0 ? (passed.to_f / count * 100).round(1) : 0.0
          }
        end
        result
      end

      private

      def scoped_checklists(tenant, date_range)
        Corvid::TenantContext.with_tenant(tenant) do
          scope = Corvid::EligibilityChecklist.all
          if date_range
            scope = scope.where(created_at: date_range)
          end
          return scope
        end
      end
    end
  end
end
