# frozen_string_literal: true

class RecordingMigrationTarget
  attr_reader :calls
  def initialize(succeed: true)
    @succeed = succeed
    @calls = []
  end
  def reconcile!(patient_ref:, bundle:)
    @calls << { patient_ref: patient_ref, bundle: bundle }
    { success: @succeed, posted: @succeed ? bundle.entries.size : 0 }
  end
  def received_types
    @calls.flat_map { |c| c[:bundle].entries.map { |e| e.resource_type.to_s } }
  end
end
