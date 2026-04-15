# frozen_string_literal: true

module Corvid
  # Tracks the 7 PRC eligibility documentation categories required by
  # 2 CFR § 200.303. Each item maps to a deficiency category from the
  # FY23 audit finding (#2023-005):
  #
  #   1. application_complete       (22/60 missing)
  #   2. identity_verified          (40/60 missing)
  #   3. insurance_verified         (5/60 missing)
  #   4. residency_verified         (15/60 missing)
  #   5. enrollment_verified        (5/60 missing)
  #   6. clinical_necessity_documented (part of 41/60 catch-all)
  #   7. management_approved        (53/60 missing)
  class EligibilityChecklist < ::ActiveRecord::Base
    self.table_name = "corvid_eligibility_checklists"

    include TenantScoped

    belongs_to :prc_referral, class_name: "Corvid::PrcReferral"

    ITEMS = %i[
      application_complete
      identity_verified
      insurance_verified
      residency_verified
      enrollment_verified
      clinical_necessity_documented
      management_approved
    ].freeze

    NON_APPROVAL_ITEMS = (ITEMS - [:management_approved]).freeze

    # Item metadata: boolean field -> timestamp field, source/by field
    ITEM_FIELDS = {
      application_complete:          { at: :application_completed_at,          by: :application_completed_by },
      identity_verified:             { at: :identity_verified_at,              source: :identity_verification_source },
      insurance_verified:            { at: :insurance_verified_at,             source: :insurance_verification_source },
      residency_verified:            { at: :residency_verified_at,             source: :residency_verification_source },
      enrollment_verified:           { at: :enrollment_verified_at,            source: :enrollment_verification_source },
      clinical_necessity_documented: { at: :clinical_necessity_documented_at,  source: :clinical_necessity_documentation_source },
      management_approved:           { at: :management_approved_at,            by: :management_approved_by }
    }.freeze

    def complete?
      ITEMS.all? { |item| send(item) }
    end

    def missing_items
      ITEMS.reject { |item| send(item) }
    end

    def compliance_percentage
      completed = ITEMS.count { |item| send(item) }
      (completed.to_f / ITEMS.size * 100).round(2)
    end

    def items_except_approval_complete?
      NON_APPROVAL_ITEMS.all? { |item| send(item) }
    end

    def verify_item!(item, source: nil, by: nil)
      item = item.to_sym
      fields = ITEM_FIELDS.fetch(item)
      validate_verify_item_metadata!(item, fields, source: source, by: by)

      attrs = { item => true, fields[:at] => Time.current }
      attrs[fields[:source]] = source if fields.key?(:source)
      attrs[fields[:by]] = by if fields.key?(:by)

      update!(attrs)
    end

    private

    def validate_verify_item_metadata!(item, fields, source:, by:)
      if fields.key?(:source)
        raise ArgumentError, "#{item} requires source:" if source.nil?
      elsif !source.nil?
        raise ArgumentError, "#{item} does not support source:"
      end

      if fields.key?(:by)
        raise ArgumentError, "#{item} requires by:" if by.nil?
      elsif !by.nil?
        raise ArgumentError, "#{item} does not support by:"
      end
    end
  end
end
