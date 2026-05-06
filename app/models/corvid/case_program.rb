# frozen_string_literal: true

module Corvid
  # Tracks program enrollment per case (IHS CHS, Medicaid, Medicare, etc.).
  # A case may have multiple program enrollments with non-overlapping codes.
  class CaseProgram < ::ActiveRecord::Base
    self.table_name = "corvid_case_programs"

    include TenantScoped

    belongs_to :case, class_name: "Corvid::Case"

    enum :enrollment_status, {
      active: "active",
      inactive: "inactive",
      pending: "pending",
      terminated: "terminated"
    }

    validates :program_name, presence: true
    validates :program_code, presence: true
    validates :program_code, uniqueness: { scope: :case_id }
    validate :program_code_in_registry, if: -> { program_code.present? }
    validates :enrollment_date, presence: true
    validate :disenrollment_after_enrollment, if: -> { disenrollment_date.present? && enrollment_date.present? }

    scope :active_enrollment, -> { where(enrollment_status: "active") }
    scope :for_program, ->(code) { where(program_code: code) }
    scope :currently_enrolled, -> { active_enrollment.where(disenrollment_date: nil) }

    def enrolled?
      active? || pending?
    end

    def disenrolled?
      disenrollment_date.present?
    end

    def disenroll!(as_of: Date.current)
      update!(disenrollment_date: as_of, enrollment_status: :terminated)
    end

    private

    def disenrollment_after_enrollment
      return unless disenrollment_date < enrollment_date

      errors.add(:disenrollment_date, "must be on or after enrollment date")
    end

    def program_code_in_registry
      return if Corvid::ProgramRegistry.exists?(program_code)

      errors.add(:program_code, "is not a registered program")
    end
  end
end
