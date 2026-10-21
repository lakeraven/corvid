# frozen_string_literal: true

module Corvid
  # Id segment of a FHIR relative reference ("Type/id").
  #
  # Ruby's split drops trailing empty fields, so "Patient/".split("/").last
  # is "Patient". Keep those fields (split limit -1), then drop an empty or
  # whitespace id. Blank input is nil. The raw reference is never returned.
  module FhirReference
    def self.id_from(ref)
      return nil if ref.blank?

      ref.split("/", -1).last.strip.presence
    end
  end
end
