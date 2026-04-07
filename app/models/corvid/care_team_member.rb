# frozen_string_literal: true

module Corvid
  class CareTeamMember < ::ActiveRecord::Base
    self.table_name = "corvid_care_team_members"

    belongs_to :care_team, class_name: "Corvid::CareTeam"

    validates :practitioner_identifier, presence: true

    scope :active, -> { where(end_date: nil).or(where("end_date >= ?", Date.current)) }
    scope :leads, -> { where(lead: true) }

    def practitioner
      Corvid.adapter.find_practitioner(practitioner_identifier)
    end
  end
end
