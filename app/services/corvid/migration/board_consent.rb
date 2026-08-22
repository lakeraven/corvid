# frozen_string_literal: true

module Corvid
  module Migration
    # A Data Governance Board consent decision for a migration.
    BoardConsent = Data.define(:granted, :consented_resource_types, :actor_identifier) do
      def granted? = granted
    end
  end
end
