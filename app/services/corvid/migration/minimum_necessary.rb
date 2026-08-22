# frozen_string_literal: true

module Corvid
  module Migration
    # HIPAA minimum-necessary: keep only consented resource types.
    module MinimumNecessary
      module_function

      def filter(bundle, allowed_types)
        allowed = Array(allowed_types).map { |t| t.to_s.strip.downcase }
        entries = bundle.entries.select { |e| allowed.include?(e.resource_type.to_s.downcase) }
        Corvid::MigrationBundle.new(patient_ref: bundle.patient_ref, entries: entries)
      end
    end
  end
end
