# frozen_string_literal: true

module Corvid
  class CareTeam < ::ActiveRecord::Base
    self.table_name = "corvid_care_teams"

    include TenantScoped

    has_many :care_team_members, dependent: :destroy, class_name: "Corvid::CareTeamMember"
    has_many :cases, class_name: "Corvid::Case"

    enum :status, { active: "active", inactive: "inactive" }

    scope :active_teams, -> { where(status: "active") }

    validates :name, presence: true

    def add_member!(role:, practitioner_identifier:, lead: false, start_date: nil, end_date: nil)
      if lead
        care_team_members.where(lead: true).update_all(lead: false)
      end
      care_team_members.create!(
        role: role,
        practitioner_identifier: practitioner_identifier,
        lead: lead,
        start_date: start_date,
        end_date: end_date
      )
    end

    def remove_member!(practitioner_identifier)
      care_team_members.where(practitioner_identifier: practitioner_identifier).destroy_all
    end

    def lead_member
      care_team_members.where(lead: true).first
    end

    def active_members
      care_team_members.active
    end

    def self.for_patient(patient_identifier)
      Corvid.adapter.get_care_team(patient_identifier)
    end

    def to_fhir
      {
        resourceType: "CareTeam",
        id: id&.to_s,
        status: status,
        name: name,
        managingOrganization: facility_identifier.present? ? [{ reference: "Organization/#{facility_identifier}" }] : nil,
        participant: care_team_members.active.map do |m|
          {
            role: [{ text: m.role }],
            member: { reference: "Practitioner/#{m.practitioner_identifier}" }
          }
        end
      }.compact
    end
  end
end
