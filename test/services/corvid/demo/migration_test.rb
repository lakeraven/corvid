# frozen_string_literal: true

require "test_helper"

# Red-first spec for the reusable PRC governed-migration demo (seed +
# orchestration). Proves the sovereignty gate is real: the consented hero
# migrates and the INJECTED target actually receives the consented entries;
# the non-consented hero HALTS with a "denied" audit Determination and NOTHING
# reaches the target. Uses the in-process StubMigrationTarget so it runs offline.
class Corvid::Demo::MigrationTest < ActiveSupport::TestCase
  TENANT = "tnt_broken_rock_demo_test"
  LEGACY_HERO_IDS = %w[pt_broken_rock_hero_1 pt_broken_rock_hero_2].freeze

  setup do
    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
  end

  test "consented hero migrates and the target receives the consented entries" do
    target = Corvid::Demo::StubMigrationTarget.new
    outcomes = Corvid::Demo::Migration.run!(tenant: TENANT, target: target)

    hero1 = outcomes.find(&:consented)
    assert hero1.result.migrated?, "Expected the consented hero to migrate"

    with_tenant(TENANT) do
      kase = Corvid::Case.find_by!(patient_identifier: hero1.patient_ref)
      assert_equal "approved", kase.reload.latest_determination.outcome
    end

    hero1_call = target.calls.find { |c| c[:patient_ref] == hero1.patient_ref }
    assert hero1_call, "Expected the target to receive hero-1's bundle"
    assert_equal %w[Patient Condition Observation],
                 hero1_call[:bundle].entries.map(&:resource_type),
                 "the target must receive exactly the consented entries"
  end

  test "non-consented hero halts and records a denied determination" do
    target = Corvid::Demo::StubMigrationTarget.new
    outcomes = Corvid::Demo::Migration.run!(tenant: TENANT, target: target)

    hero2 = outcomes.reject(&:consented).first
    assert hero2.result.halted?, "Expected the non-consented hero to halt"

    with_tenant(TENANT) do
      kase = Corvid::Case.find_by!(patient_identifier: hero2.patient_ref)
      assert_equal "denied", kase.reload.latest_determination.outcome
    end

    assert target.calls.none? { |c| c[:patient_ref] == hero2.patient_ref },
           "non-consented hero data must NEVER reach the target"
  end

  test "reset! removes the seeded hero cases" do
    Corvid::Demo::Migration.seed!(tenant: TENANT)
    Corvid::Demo::Migration.reset!(tenant: TENANT)
    with_tenant(TENANT) do
      assert_equal 0,
                   Corvid::Case.where(patient_identifier: Corvid::Demo::Migration::HEROES.keys).count
    end
  end

  test "reset! removes legacy underscore Broken Rock hero cases alongside current heroes" do
    with_tenant(TENANT) do
      LEGACY_HERO_IDS.each do |patient_ref|
        Corvid::Case.find_or_create_by!(
          tenant_identifier: TENANT,
          facility_identifier: Corvid::Demo::Migration::FACILITY,
          patient_identifier: patient_ref
        ) do |c|
          c.status = "active"
          c.lifecycle_status = "intake"
          c.intake_at = Time.current
        end
      end
      Corvid::Demo::Migration.seed!(tenant: TENANT)
      assert_equal 4, Corvid::Case.where(patient_identifier: LEGACY_HERO_IDS + Corvid::Demo::Migration::HEROES.keys).count
    end

    Corvid::Demo::Migration.reset!(tenant: TENANT)
    with_tenant(TENANT) do
      assert_equal 0, Corvid::Case.where(patient_identifier: LEGACY_HERO_IDS + Corvid::Demo::Migration::HEROES.keys).count
    end
  end

  test "reset then seed after a legacy-only database leaves exactly the current hero pair" do
    with_tenant(TENANT) do
      LEGACY_HERO_IDS.each do |patient_ref|
        Corvid::Case.find_or_create_by!(
          tenant_identifier: TENANT,
          facility_identifier: Corvid::Demo::Migration::FACILITY,
          patient_identifier: patient_ref
        ) do |c|
          c.status = "active"
          c.lifecycle_status = "intake"
          c.intake_at = Time.current
        end
      end
    end

    Corvid::Demo::Migration.reset!(tenant: TENANT)
    Corvid::Demo::Migration.seed!(tenant: TENANT)
    with_tenant(TENANT) do
      assert_equal 2, Corvid::Case.where(patient_identifier: Corvid::Demo::Migration::HEROES.keys).count
      LEGACY_HERO_IDS.each do |legacy_id|
        refute Corvid::Case.exists?(patient_identifier: legacy_id),
               "expected legacy hero #{legacy_id} to be removed"
      end
    end
  end
end
