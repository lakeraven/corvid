# frozen_string_literal: true

require "test_helper"

class Corvid::PolymorphicTenantTest < ActiveSupport::TestCase
  TENANT = "tnt_pt"

  test "Task with same-tenant taskable is valid" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pt_a")
      task = Corvid::Task.new(taskable: kase, description: "test")
      assert task.valid?
    end
  end

  test "Task cannot be created across tenants" do
    kase = nil
    Corvid::TenantContext.with_tenant("tnt_a") do
      kase = Corvid::Case.create!(patient_identifier: "pt_pt_b")
    end

    Corvid::TenantContext.with_tenant("tnt_b") do
      task = Corvid::Task.new(taskable: kase, description: "leak attempt")
      refute task.valid?
      assert_match(/same tenant/, task.errors[:taskable].first)
    end
  end

  test "Determination cannot reference cross-tenant determinable" do
    kase = nil
    Corvid::TenantContext.with_tenant("tnt_x") do
      kase = Corvid::Case.create!(patient_identifier: "pt_pt_c")
    end

    Corvid::TenantContext.with_tenant("tnt_y") do
      det = Corvid::Determination.new(determinable: kase, decision_method: "automated", outcome: "approved")
      refute det.valid?
      assert_match(/same tenant/, det.errors[:determinable].first)
    end
  end

  test "all 9 corvid models are loadable" do
    %w[
      Corvid::Case
      Corvid::PrcReferral
      Corvid::Task
      Corvid::CareTeam
      Corvid::CareTeamMember
      Corvid::CommitteeReview
      Corvid::Determination
      Corvid::AlternateResourceCheck
      Corvid::FeeSchedule
    ].each do |class_name|
      klass = class_name.constantize
      assert klass < ActiveRecord::Base, "#{class_name} should be an AR model"
      assert_match(/\Acorvid_/, klass.table_name, "#{class_name}.table_name should start with corvid_")
    end
  end
end
