# frozen_string_literal: true

# The dummy host is a configured deployment. ADR 0008 writes an HMAC
# fingerprint only when a key is present, so existing examples that record
# a decision still get one. The bytes are synthetic, not a secret.
# Corvid.reset_configuration! drops host config; the test setup puts it
# back the way a boot initializer does. An example that needs the
# unconfigured path resets configuration inside the example.
module CorvidDummySnapshotKey
  VERSION = "dummy-v1"
  KEY = "dummy-host-snapshot-hmac-key-v1-xxxxxx"

  module_function

  def install!
    config = Corvid.configuration
    return if config.verification_snapshot_keys.present?
    return if config.verification_snapshot_key_version.present?

    config.verification_snapshot_keys = { VERSION => KEY }
    config.verification_snapshot_key_version = VERSION
  end
end

Corvid.configure do |c|
  c.adapter = Corvid::Adapters::MockAdapter.new
end

CorvidDummySnapshotKey.install!

ActiveSupport.on_load(:active_support_test_case) do
  setup { CorvidDummySnapshotKey.install! }
end
