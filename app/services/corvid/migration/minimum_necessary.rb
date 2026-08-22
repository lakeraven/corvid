# frozen_string_literal: true

module Corvid
  module Migration
    # HIPAA minimum-necessary: keep only consented resource types.
    module MinimumNecessary
      module_function

      def filter(bundle, allowed_types)
        allowed = Array(allowed_types).map { |t| t.to_s.strip }
        entries = bundle.entries.select { |e| allowed.include?(e.resource_type.to_s) }
        Corvid::MigrationBundle.new(patient_ref: bundle.patient_ref, entries: entries)
      end
    end
  end
end
