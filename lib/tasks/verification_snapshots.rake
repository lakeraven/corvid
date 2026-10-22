# frozen_string_literal: true

namespace :corvid do
  namespace :verification_snapshots do
    # Re-runnable companion to the scrub migration (ADR 0008). Run it after
    # old application instances are retired, to clear plain hashes they
    # wrote during a rolling deploy. Prints a count only.
    desc "Null legacy verification snapshot hashes that have no key version"
    task scrub_legacy: :environment do
      count = Corvid::PrcEligibilityDecision.with_connection do |connection|
        connection.exec_update(Corvid::SnapshotFingerprint::LEGACY_SNAPSHOT_HASH_SCRUB_SQL)
      end
      puts count
    end
  end
end
