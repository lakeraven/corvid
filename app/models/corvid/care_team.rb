# frozen_string_literal: true

module Corvid
  class CareTeam < ::ActiveRecord::Base
    self.table_name = "corvid_care_teams"

    include TenantScoped

    has_many :care_team_members, dependent: :destroy, class_name: "Corvid::CareTeamMember"
    has_many :cases, class_name: "Corvid::Case"

    enum :status, { active: "active", inactive: "inactive" }

    validates :name, presence: true

    def add_member!(role:, practitioner_identifier:, lead: false, start_date: nil, end_date: nil)
      care_team_members.create!(
        role: role,
        practitioner_identifier: practitioner_identifier,
        lead: lead,
        start_date: start_date,
        end_date: end_date
      )
    end

    # Patient-specific care teams via the adapter (EHR-sourced).
    def self.for_patient(patient_identifier)
      Corvid.adapter.get_care_team(patient_identifier)
    end
  end
end
