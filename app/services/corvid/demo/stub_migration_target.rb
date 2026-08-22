# frozen_string_literal: true

module Corvid
  module Demo
    # In-process transport stub for OFFLINE demos of the governed migration.
    # Records what WOULD have been relayed and reports a truthful posted count.
    # Clearly labeled — never a stand-in presented as a live EHR. A host (e.g.
    # corvid-saas) injects a real transport for a live relay; this exists only
    # so the governance flow is demonstrable without a backend.
    #
    # Satisfies the Corvid::GovernedMigration target contract:
    #   reconcile!(patient_ref:, bundle:) -> Hash (:success, :posted)
    class StubMigrationTarget
      attr_reader :calls

      def initialize(succeed: true)
        @succeed = succeed
        @calls = []
      end

      def label
        "STUB (in-process — no live EHR; host injects a real target for a live run)"
      end

      def reconcile!(patient_ref:, bundle:)
        @calls << { patient_ref: patient_ref, bundle: bundle }
        {
          success: @succeed,
          posted: @succeed ? bundle.entries.size : 0,
          patient_dfn: "STUB-#{patient_ref}",
          responses: bundle.entries.map { |e| { resource_type: e.resource_type, status: 201 } }
        }
      end

      def confirm(identifier:)
        {
          "resourceType" => "Bundle",
          "total" => 1,
          "entry" => [ { "resource" => { "resourceType" => "Patient", "id" => "STUB-#{identifier}" } } ]
        }
      end

      # Flat list of the resource types actually relayed, across all calls.
      def received_types
        @calls.flat_map { |c| c[:bundle].entries.map { |e| e.resource_type.to_s } }
      end
    end
  end
end
