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
      # Wrap in a transaction so a validation failure on the new member
      # doesn't leave the team lead-less (we used to demote first, then
      # create; if create! raised, the old lead stayed demoted).
      transaction do
        new_member = care_team_members.create!(
          role: role,
          practitioner_identifier: practitioner_identifier,
          lead: lead,
          start_date: start_date,
          end_date: end_date
        )
        if lead
          care_team_members.where(lead: true)
            .where.not(id: new_member.id)
            .update_all(lead: false)
        end
        new_member
      end
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

    # Adapter-sourced care team for an external patient identifier.
    # NOT an AR scope — this resolves the EHR-owned care team (e.g. RPMS
    # Patient Care Team) via Corvid.adapter.get_care_team, which returns
    # a plain data structure (array of CareTeamMemberReference), not
    # CareTeam AR rows. Engine-owned care teams are accessed through
    # the usual .where / instance methods.
    def self.for_patient(patient_identifier)
      Corvid.adapter.get_care_team(patient_identifier)
    end

    # Lightweight FHIR R4 CareTeam projection for host apps that want a
    # JSON preview (e.g. dashboards). NOT validated against the FHIR R4
    # profile or any IG — status code system is omitted, participant
    # role is a free-text CodeableConcept, and the resource is not
    # rendered through an R4 model. Host apps that need conformance
    # should re-serialize through fhir_models or similar.
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
