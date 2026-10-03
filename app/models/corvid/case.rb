# frozen_string_literal: true

module Corvid
  # The core Case-domain record. Holds workflow state for a person's
  # authorization lifecycle. Per ADR 0003, no PHI is stored at rest:
  # patient details are resolved via the adapter, and free-text fields
  # are vault tokens (notes_token, conditions_token).
  #
  # patient_identifier is an opaque external token (per ADR 0001) — not
  # a Rails FK. Do NOT add belongs_to :patient.
  class Case < ::ActiveRecord::Base
    self.table_name = "corvid_cases"

    include TenantScoped
    include Determinable

    belongs_to :care_team, optional: true, class_name: "Corvid::CareTeam"
    has_many :prc_referrals, dependent: :destroy, class_name: "Corvid::PrcReferral"
    has_many :tasks, as: :taskable, dependent: :destroy, class_name: "Corvid::Task"
    has_many :case_programs, dependent: :destroy, class_name: "Corvid::CaseProgram"

    enum :status, { active: "active", inactive: "inactive", closed: "closed" }
    LIFECYCLE_STATUSES = %w[intake active_followup closure closed].freeze

    validates :patient_identifier, presence: true
    validates :lifecycle_status, inclusion: { in: LIFECYCLE_STATUSES }

    scope :for_program, lambda { |code|
      joins(:case_programs).where(corvid_case_programs: { program_code: code })
    }
    scope :in_lifecycle, ->(status) { where(lifecycle_status: status) }

    # Resolve patient via adapter. Returns a Corvid::PatientReference or nil.
    # Per ADR 0003, the engine never persists patient PHI; this is in-memory
    # only for the request duration.
    def patient
      @patient ||= Corvid.adapter.find_patient(patient_identifier)
    end

    # Display name, resolved through the adapter for the request duration only.
    # There is deliberately no cached fallback: ADR 0003's criterion is that a
    # corvid dump reveals no PHI, and a cached name is PHI at rest whether or
    # not a host elected to populate it. Without vault access this degrades to
    # a placeholder, which is the intended failure — a missing name is a
    # smaller problem than a name nobody meant to store.
    def display_name
      patient&.display_name || "Unknown Patient"
    end

    def program_case?
      case_programs.exists?
    end
  end
end
