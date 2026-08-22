class RecordingMigrationTarget
  attr_reader :calls
  def initialize; @calls = []; end
  def reconcile!(patient_ref:, bundle:)
    @calls << { patient_ref: patient_ref, bundle: bundle }
    { success: true, posted: bundle.entries.size }
  end
  def received_types
    @calls.flat_map { |c| c[:bundle].entries.map { |e| e.resource_type.to_s } }
  end
end
