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
    PROGRAM_TYPES = %w[immunization sti tb neonatal lead hep_b communicable_disease].freeze

    validates :patient_identifier, presence: true
    validates :program_type, inclusion: { in: PROGRAM_TYPES }, allow_nil: true
    validates :lifecycle_status, inclusion: { in: LIFECYCLE_STATUSES }

    scope :for_program, ->(type) { where(program_type: type) }
    scope :in_lifecycle, ->(status) { where(lifecycle_status: status) }

    # Resolve patient via adapter. Returns a Corvid::PatientReference or nil.
    # Per ADR 0003, the engine never persists patient PHI; this is in-memory
    # only for the request duration.
    def patient
      @patient ||= Corvid.adapter.find_patient(patient_identifier)
    end

    # Display name with cache fallback. Per ADR 0003, patient_name_cached
    # is OPTIONAL — hosts that prefer zero-PHI-at-rest leave it nil.
    def display_name
      patient_name_cached || patient&.display_name || "Unknown Patient"
    end

    # Cache patient data for offline display. Hosts call this only if they
    # accept the duplicated-PHI trade-off.
    def cache_patient_data!
      if (p = patient)
        update!(patient_name_cached: p.display_name, patient_dob_cached: p.dob)
      end
    end

    def program_case?
      program_type.present?
    end
  end
end
