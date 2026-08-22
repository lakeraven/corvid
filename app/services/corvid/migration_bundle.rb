# frozen_string_literal: true

module Corvid
  # Transport-neutral, request-scoped migration payload. Corvid holds no PHI
  # at rest; this exists only in-flight.
  class MigrationBundle
    Entry = Data.define(:resource_type, :data)
    attr_reader :patient_ref, :entries
    def initialize(patient_ref:, entries: [])
      @patient_ref = patient_ref
      @entries = entries.map { |e| e.is_a?(Entry) ? e : Entry.new(resource_type: e[:resource_type], data: e[:data]) }
    end
    def resource_types = entries.map(&:resource_type)
  end
end
