# frozen_string_literal: true

module Corvid
  class CareTeamMember < ::ActiveRecord::Base
    self.table_name = "corvid_care_team_members"

    belongs_to :care_team, class_name: "Corvid::CareTeam"

    # String enum (ADR 0002), stored as text and constrained by a CHECK.
    # Display text is fixed per code and never echoes the code (ADR 0003).
    ROLE_LABELS = {
      "primary_care_provider" => "Primary care provider",
      "care_manager" => "Care manager",
      "consultant" => "Consultant",
      "other" => "Other"
    }.freeze

    attribute :role_code, :string
    enum :role_code, {
      primary_care_provider: "primary_care_provider",
      care_manager: "care_manager",
      consultant: "consultant",
      other: "other"
    }, validate: true

    validates :practitioner_identifier, presence: true

    scope :active, -> { where(end_date: nil).or(where("end_date >= ?", Date.current)) }
    scope :inactive, -> { where("end_date < ?", Date.current) }
    scope :leads, -> { where(lead: true) }

    def active?
      end_date.nil? || end_date >= Date.current
    end

    def inactive?
      !active?
    end

    def role_display
      ROLE_LABELS[role_code]
    end

    def practitioner
      Corvid.adapter.find_practitioner(practitioner_identifier)
    end
  end
end
