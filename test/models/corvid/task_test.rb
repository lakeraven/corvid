# frozen_string_literal: true

require "test_helper"

class Corvid::TaskTest < ActiveSupport::TestCase
  TENANT = "tnt_task_test"

  setup do
    Corvid::Task.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # BASIC CREATION
  # =============================================================================

  test "creates task with description" do
    with_tenant(TENANT) do
      task = create_task(description: "Follow up on lab results")
      assert task.persisted?
      assert_equal "Follow up on lab results", task.description
    end
  end

  test "requires description" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(taskable: create_case, description: nil)
      refute task.valid?
      assert task.errors[:description].any?
    end
  end

  test "defaults to pending status" do
    with_tenant(TENANT) do
      assert create_task.pending?
    end
  end

  test "defaults to routine priority" do
    with_tenant(TENANT) do
      assert create_task.priority_routine?
    end
  end

  # =============================================================================
  # STATUS TRANSITIONS
  # =============================================================================

  test "can transition to in_progress" do
    with_tenant(TENANT) do
      task = create_task
      task.in_progress!
      assert task.in_progress?
    end
  end

  test "can transition to completed" do
    with_tenant(TENANT) do
      task = create_task
      task.completed!
      assert task.completed?
      assert task.completed_at.present?
    end
  end

  test "sets completed_at when completing" do
    with_tenant(TENANT) do
      task = create_task
      freeze_time do
        task.completed!
        assert_equal Time.current, task.completed_at
      end
    end
  end

  test "can be cancelled" do
    with_tenant(TENANT) do
      task = create_task
      task.cancelled!
      assert task.cancelled?
    end
  end

  test "can be put on hold" do
    with_tenant(TENANT) do
      task = create_task
      task.on_hold!
      assert task.on_hold?
    end
  end

  # =============================================================================
  # PRIORITY
  # =============================================================================

  test "can set urgent priority" do
    with_tenant(TENANT) do
      task = create_task(priority: :urgent)
      assert task.priority_urgent?
    end
  end

  test "can set stat priority" do
    with_tenant(TENANT) do
      task = create_task(priority: :stat)
      assert task.priority_stat?
    end
  end

  # =============================================================================
  # ASSIGNMENT
  # =============================================================================

  test "assign_to! sets assignee" do
    with_tenant(TENANT) do
      task = create_task
      task.assign_to!("pr_001")
      assert_equal "pr_001", task.assignee_identifier
    end
  end

  test "unassign! clears assignee" do
    with_tenant(TENANT) do
      task = create_task
      task.assign_to!("pr_001")
      task.unassign!
      assert_nil task.assignee_identifier
    end
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "incomplete scope excludes completed and cancelled" do
    with_tenant(TENANT) do
      completed = create_task(description: "Completed")
      completed.completed!

      cancelled = create_task(description: "Cancelled")
      cancelled.cancelled!

      pending_task = create_task(description: "Pending")
      in_progress = create_task(description: "In Progress")
      in_progress.in_progress!

      incomplete = Corvid::Task.incomplete

      refute_includes incomplete, completed
      refute_includes incomplete, cancelled
      assert_includes incomplete, pending_task
      assert_includes incomplete, in_progress
    end
  end

  test "overdue scope finds tasks past due" do
    with_tenant(TENANT) do
      overdue = create_task(description: "Overdue", due_at: 1.day.ago)
      not_due_yet = create_task(description: "Future", due_at: 1.day.from_now)

      overdue_tasks = Corvid::Task.overdue

      assert_includes overdue_tasks, overdue
      refute_includes overdue_tasks, not_due_yet
    end
  end

  test "unassigned scope finds tasks without assignee" do
    with_tenant(TENANT) do
      unassigned = create_task(description: "Unassigned")
      assigned = create_task(description: "Assigned")
      assigned.assign_to!("pr_001")

      assert_includes Corvid::Task.unassigned, unassigned
      refute_includes Corvid::Task.unassigned, assigned
    end
  end

  test "for_assignee scope finds tasks for specific practitioner" do
    with_tenant(TENANT) do
      task1 = create_task(description: "Task 1")
      task1.assign_to!("pr_001")
      task2 = create_task(description: "Task 2")
      task2.assign_to!("pr_002")

      assert_includes Corvid::Task.for_assignee("pr_001"), task1
      refute_includes Corvid::Task.for_assignee("pr_001"), task2
    end
  end

  test "due_soon scope finds tasks due within window" do
    with_tenant(TENANT) do
      due_soon = create_task(description: "Due soon", due_at: 3.days.from_now)
      due_later = create_task(description: "Due later", due_at: 14.days.from_now)

      due_soon_tasks = Corvid::Task.due_soon(7)

      assert_includes due_soon_tasks, due_soon
      refute_includes due_soon_tasks, due_later
    end
  end

  test "milestones scope returns tasks with milestone_key" do
    with_tenant(TENANT) do
      milestone = create_task(description: "Milestone", milestone_key: "initial_assessment")
      regular = create_task(description: "Regular")

      assert_includes Corvid::Task.milestones, milestone
      refute_includes Corvid::Task.milestones, regular
    end
  end

  test "required_milestones scope returns required milestone tasks" do
    with_tenant(TENANT) do
      c = create_case
      required = Corvid::Task.create!(
        taskable: c, description: "Required",
        milestone_key: "intake_assessment", required: true
      )
      optional = Corvid::Task.create!(
        taskable: c, description: "Optional",
        milestone_key: "followup_assessment", required: false
      )

      assert_includes Corvid::Task.required_milestones, required
      refute_includes Corvid::Task.required_milestones, optional
    end
  end

  # =============================================================================
  # STATUS HELPERS
  # =============================================================================

  test "overdue? returns true when past due and incomplete" do
    with_tenant(TENANT) do
      task = create_task(due_at: 1.day.ago)
      assert task.overdue?
    end
  end

  test "overdue? returns false when completed" do
    with_tenant(TENANT) do
      task = create_task(due_at: 1.day.ago)
      task.completed!
      refute task.overdue?
    end
  end

  test "overdue? returns false when no due date" do
    with_tenant(TENANT) do
      task = create_task
      refute task.overdue?
    end
  end

  test "incomplete? returns true for pending tasks" do
    with_tenant(TENANT) do
      task = create_task
      assert task.incomplete?
    end
  end

  test "incomplete? returns true for in_progress tasks" do
    with_tenant(TENANT) do
      task = create_task
      task.in_progress!
      assert task.incomplete?
    end
  end

  test "incomplete? returns false for completed tasks" do
    with_tenant(TENANT) do
      task = create_task
      task.completed!
      refute task.incomplete?
    end
  end

  test "incomplete? returns false for cancelled tasks" do
    with_tenant(TENANT) do
      task = create_task
      task.cancelled!
      refute task.incomplete?
    end
  end

  test "milestone? returns true when milestone_key is present" do
    with_tenant(TENANT) do
      task = create_task(milestone_key: "initial_assessment")
      assert task.milestone?
    end
  end

  test "milestone? returns false when milestone_key is nil" do
    with_tenant(TENANT) do
      task = create_task
      refute task.milestone?
    end
  end

  # =============================================================================
  # FHIR STATUS MAPPING
  # =============================================================================

  test "resource_class returns Task" do
    assert_equal "Task", Corvid::Task.resource_class
  end

  test "fhir_status maps pending to requested" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :pending, taskable: create_case, description: "t")
      assert_equal "requested", task.fhir_status
    end
  end

  test "fhir_status maps in_progress to in-progress" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :in_progress, taskable: create_case, description: "t")
      assert_equal "in-progress", task.fhir_status
    end
  end

  test "fhir_status maps completed to completed" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :completed, taskable: create_case, description: "t")
      assert_equal "completed", task.fhir_status
    end
  end

  test "fhir_status maps cancelled to cancelled" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :cancelled, taskable: create_case, description: "t")
      assert_equal "cancelled", task.fhir_status
    end
  end

  test "fhir_status maps on_hold to on-hold" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :on_hold, taskable: create_case, description: "t")
      assert_equal "on-hold", task.fhir_status
    end
  end

  # =============================================================================
  # FHIR SERIALIZATION (to_fhir)
  # =============================================================================

  test "to_fhir returns correct resourceType" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert_equal "Task", fhir[:resourceType]
    end
  end

  test "to_fhir includes id" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert_equal task.id.to_s, fhir[:id]
    end
  end

  test "to_fhir includes status mapped to FHIR" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert_equal "requested", fhir[:status]
    end
  end

  test "to_fhir includes intent as order" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert_equal "order", fhir[:intent]
    end
  end

  test "to_fhir includes priority" do
    with_tenant(TENANT) do
      task = create_task(priority: :urgent)
      fhir = task.to_fhir
      assert_equal "urgent", fhir[:priority]
    end
  end

  test "to_fhir includes description" do
    with_tenant(TENANT) do
      task = create_task(description: "Follow up on lab results")
      fhir = task.to_fhir
      assert_equal "Follow up on lab results", fhir[:description]
    end
  end

  test "to_fhir includes focus reference for Case" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert fhir[:focus].present?
      assert_includes fhir[:focus][:reference], "EpisodeOfCare/"
    end
  end

  test "to_fhir includes focus reference for PrcReferral" do
    with_tenant(TENANT) do
      referral = Corvid::PrcReferral.create!(
        case: create_case,
        referral_identifier: "ref_#{SecureRandom.hex(4)}"
      )
      task = Corvid::Task.create!(
        taskable: referral,
        description: "Test task"
      )
      fhir = task.to_fhir
      assert fhir[:focus].present?
      assert_includes fhir[:focus][:reference], "ServiceRequest/"
    end
  end

  test "to_fhir includes owner reference when assigned" do
    with_tenant(TENANT) do
      task = create_task
      task.assign_to!("pr_101")
      fhir = task.to_fhir
      assert fhir[:owner].present?
      assert_includes fhir[:owner][:reference], "Practitioner/"
      assert_includes fhir[:owner][:reference], "pr_101"
    end
  end

  test "to_fhir has nil owner when unassigned" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert_nil fhir[:owner]
    end
  end

  test "to_fhir includes executionPeriod with due_at" do
    with_tenant(TENANT) do
      due = 3.days.from_now
      task = create_task(due_at: due)
      fhir = task.to_fhir
      assert fhir[:executionPeriod].present?
      assert_equal due.to_date.iso8601, fhir[:executionPeriod][:end]
    end
  end

  test "to_fhir has nil executionPeriod without due_at" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert_nil fhir[:executionPeriod]
    end
  end

  test "to_fhir includes authoredOn" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert fhir[:authoredOn].present?
      assert_equal task.created_at.iso8601, fhir[:authoredOn]
    end
  end

  test "to_fhir includes lastModified" do
    with_tenant(TENANT) do
      task = create_task
      fhir = task.to_fhir
      assert fhir[:lastModified].present?
      assert_equal task.updated_at.iso8601, fhir[:lastModified]
    end
  end

  # =============================================================================
  # FHIR PARSING (from_fhir_attributes)
  # =============================================================================

  test "from_fhir_attributes extracts status with reverse mapping" do
    fhir_resource = OpenStruct.new(
      status: "requested",
      intent: "order",
      description: "Test task"
    )

    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)

    assert_equal "pending", attrs[:status]
    assert_equal "Test task", attrs[:description]
  end

  test "from_fhir_attributes extracts in-progress status" do
    fhir_resource = OpenStruct.new(status: "in-progress", intent: "order")
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_equal "in_progress", attrs[:status]
  end

  test "from_fhir_attributes extracts priority" do
    fhir_resource = OpenStruct.new(
      status: "requested", intent: "order", priority: "urgent"
    )
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_equal "urgent", attrs[:priority]
  end

  test "from_fhir_attributes extracts owner reference" do
    fhir_resource = OpenStruct.new(
      status: "requested", intent: "order",
      owner: OpenStruct.new(reference: "Practitioner/rpms-practitioner-101")
    )
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_equal 101, attrs[:assignee_id]
  end

  test "from_fhir_attributes parses executionPeriod end as due_at" do
    fhir_resource = OpenStruct.new(
      status: "requested", intent: "order",
      executionPeriod: OpenStruct.new(end: "2026-03-01T12:00:00Z")
    )
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_instance_of ActiveSupport::TimeWithZone, attrs[:due_at]
  end

  test "from_fhir_attributes skips unmapped FHIR status" do
    fhir_resource = OpenStruct.new(
      status: "draft", intent: "order", description: "Test task"
    )
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_nil attrs[:status]
    assert_equal "Test task", attrs[:description]
  end

  test "from_fhir_attributes handles missing status" do
    fhir_resource = OpenStruct.new(intent: "order", description: "No status task")
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_nil attrs[:status]
    assert_equal "No status task", attrs[:description]
  end

  test "from_fhir_attributes handles nil owner" do
    fhir_resource = OpenStruct.new(status: "requested", intent: "order")
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_nil attrs[:assignee_id]
  end

  test "from_fhir_attributes handles non-Practitioner owner reference" do
    fhir_resource = OpenStruct.new(
      status: "requested", intent: "order",
      owner: OpenStruct.new(reference: "Organization/ORG1")
    )
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_nil attrs[:assignee_id]
  end

  test "from_fhir_attributes handles missing executionPeriod" do
    fhir_resource = OpenStruct.new(status: "requested", intent: "order")
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_nil attrs[:due_at]
  end

  test "from_fhir_attributes handles nil executionPeriod end" do
    fhir_resource = OpenStruct.new(
      status: "requested", intent: "order",
      executionPeriod: OpenStruct.new(end: nil)
    )
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_nil attrs[:due_at]
  end

  # =============================================================================
  # ROUND-TRIP
  # =============================================================================

  test "to_fhir → from_fhir_attributes round-trip preserves core data" do
    with_tenant(TENANT) do
      due = Date.parse("2026-03-01")
      task = create_task(
        description: "Follow up on lab results",
        priority: :urgent,
        due_at: due
      )
      task.assign_to!("pr_101")

      fhir = task.to_fhir
      # Simulate OpenStruct for from_fhir_attributes
      fhir_os = OpenStruct.new(fhir.transform_keys(&:to_s).transform_keys { |k|
        k == "resourceType" ? :resourceType : k.to_sym
      })

      attrs = Corvid::Task.from_fhir_attributes(fhir_os)

      assert_equal "pending", attrs[:status]
      assert_equal "Follow up on lab results", attrs[:description]
      assert_equal "urgent", attrs[:priority]
    end
  end

  test "to_fhir → from_fhir_attributes round-trip for all status values" do
    with_tenant(TENANT) do
      %i[pending in_progress completed cancelled on_hold].each do |status|
        task = Corvid::Task.new(status: status, taskable: create_case, description: "t")
        fhir = task.to_fhir
        fhir_os = OpenStruct.new(status: fhir[:status])
        attrs = Corvid::Task.from_fhir_attributes(fhir_os)

        assert_equal status.to_s, attrs[:status],
          "Round-trip failed for status #{status}"
      end
    end
  end

  # =============================================================================
  # MULTI-TENANCY
  # =============================================================================

  test "tasks are scoped to current tenant" do
    my_task = nil
    other_task = nil

    with_tenant("tenant_a") do
      my_task = create_task(description: "My task")
    end

    with_tenant("tenant_b") do
      other_task = create_task(description: "Other task")
    end

    with_tenant("tenant_a") do
      visible = Corvid::Task.all
      assert_includes visible, my_task
      refute_includes visible, other_task
    end
  end

  # =============================================================================
  # MILESTONE FIELDS
  # =============================================================================

  test "milestone_key is unique per taskable" do
    with_tenant(TENANT) do
      c = create_case
      Corvid::Task.create!(
        taskable: c, description: "First", milestone_key: "intake"
      )
      assert_raises(ActiveRecord::RecordNotUnique) do
        Corvid::Task.create!(
          taskable: c, description: "Duplicate", milestone_key: "intake"
        )
      end
    end
  end

  test "same milestone_key allowed on different taskables" do
    with_tenant(TENANT) do
      c1 = create_case
      c2 = Corvid::Case.create!(
        patient_identifier: "pt_other",
        lifecycle_status: "intake",
        facility_identifier: "fac_test"
      )
      t1 = Corvid::Task.create!(taskable: c1, description: "A", milestone_key: "intake")
      t2 = Corvid::Task.create!(taskable: c2, description: "B", milestone_key: "intake")
      assert t1.persisted?
      assert t2.persisted?
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: "pt_task_test",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_task(description: "Test task", **attrs)
    Corvid::Task.create!(
      taskable: attrs.delete(:taskable) || create_case,
      description: description,
      **attrs
    )
  end
end
