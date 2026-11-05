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

    # Coding system for CareTeam.participant.role. Display comes from
    # CareTeamMember#role_display, not from free text.
    FHIR_ROLE_SYSTEM = "urn:corvid:care-team-role"

    def add_member!(role_code:, practitioner_identifier:, lead: false, start_date: nil, end_date: nil)
      # Wrap in a transaction so a validation failure on the new member
      # doesn't leave the team lead-less (we used to demote first, then
      # create; if create! raised, the old lead stayed demoted).
      transaction do
        new_member = care_team_members.create!(
          role_code: role_code,
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
    # NOT an AR scope — this resolves the EHR-owned care team via
    # Corvid.adapter.get_care_team. nil means the source did not answer
    # and is returned as nil, never coerced to []. [] means the source
    # answered "none". An Array is CareTeamMemberReference values, not
    # CareTeam AR rows. Engine-owned care teams are accessed through
    # the usual .where / instance methods.
    def self.for_patient(patient_identifier)
      members = Corvid.adapter.get_care_team(patient_identifier)
      return nil if members.nil?

      members
    end

    # Lightweight FHIR R4 CareTeam projection for host apps that want a
    # JSON preview (e.g. dashboards). NOT validated against the FHIR R4
    # profile or any IG — status code system is omitted, participant
    # role is the engine code plus its derived display, and the resource
    # is not rendered through an R4 model. Host apps that need conformance
    # should re-serialize through fhir_models or similar.
    def to_fhir
      {
        resourceType: "CareTeam",
        id: id&.to_s,
        status: status,
        name: name,
        managingOrganization: facility_identifier.present? ? [ { reference: "Organization/#{facility_identifier}" } ] : nil,
        participant: care_team_members.active.map { |member| fhir_participant(member) }
      }.compact
    end

    private

    def fhir_participant(member)
      {
        role: [ fhir_role(member) ],
        member: { reference: "Practitioner/#{member.practitioner_identifier}" }
      }
    end

    def fhir_role(member)
      {
        coding: [ {
          system: FHIR_ROLE_SYSTEM,
          code: member.role_code,
          display: member.role_display
        } ]
      }
    end
  end
end
