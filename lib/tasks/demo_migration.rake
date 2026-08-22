# frozen_string_literal: true

# Reusable PRC governed patient-data migration demo (seed + orchestration).
#
# Stages a FULLY SYNTHETIC "Broken Rock" scenario — no real tribe, facility,
# person, or PHI — and runs Corvid::Demo::Migration through the in-process
# StubMigrationTarget so the governance flow (Data Governance Board consent
# gate, minimum-necessary filter, audit Determination) is demonstrable OFFLINE.
# A host injects a real transport (e.g. corvid-saas's LakeravenEhrTarget) for a
# live relay.
#
#   bin/rails demo:migrate          # seed + run (migrate vs halt) per hero
#   bin/rails demo:migration_reset  # clear the seeded rows
namespace :demo do
  desc "Seed the synthetic Broken Rock scenario and run the governed migration per hero (in-process stub target)"
  task migrate: :environment do
    target = Corvid::Demo::StubMigrationTarget.new
    puts "== Reusable PRC governed migration demo =="
    puts "Tenant:    #{Corvid::Demo::Migration::DEFAULT_TENANT}"
    puts "Transport: #{target.label}"
    puts ""

    Corvid::Demo::Migration.run!(target: target).each do |outcome|
      result = outcome.result
      puts "Patient #{outcome.patient_ref} (#{outcome.name}):"
      if result.migrated?
        posted = result.target_response && (result.target_response[:posted] || result.target_response["posted"])
        puts "  -> MIGRATED  (posted #{posted} entries)"
      else
        puts "  -> HALTED    #{result.reason}"
      end
      puts "  -> AUDIT     determination #{result.determination&.outcome || '(none)'}"
      puts ""
    end
  end

  desc "Clear the seeded synthetic Broken Rock scenario"
  task migration_reset: :environment do
    count = Corvid::Demo::Migration.reset!
    puts "demo:migration_reset — removed #{count} Broken Rock hero case(s) and their determinations."
  end
end
