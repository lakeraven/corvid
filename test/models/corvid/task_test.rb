# frozen_string_literal: true

require "test_helper"

class Corvid::TaskTest < ActiveSupport::TestCase
  TENANT = "tnt_task_test"

  setup do
    Corvid::Task.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # -- Creation ---------------------------------------------------------------

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

  # -- Status transitions -----------------------------------------------------

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
    end
  end

  test "can transition to cancelled" do
    with_tenant(TENANT) do
      task = create_task
      task.cancelled!
      assert task.cancelled?
    end
  end

  test "can transition to on_hold" do
    with_tenant(TENANT) do
      task = create_task
      task.on_hold!
      assert task.on_hold?
    end
  end

  # -- Assignment -------------------------------------------------------------

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

  # -- Scopes -----------------------------------------------------------------

  test "incomplete scope returns pending and in_progress" do
    with_tenant(TENANT) do
      pending_task = create_task(description: "Pending")
      ip_task = create_task(description: "In progress")
      ip_task.in_progress!
      completed = create_task(description: "Done")
      completed.completed!

      incomplete = Corvid::Task.incomplete
      assert_includes incomplete, pending_task
      assert_includes incomplete, ip_task
      refute_includes incomplete, completed
    end
  end

  test "overdue scope returns incomplete tasks past due" do
    with_tenant(TENANT) do
      overdue = create_task(description: "Overdue", due_at: 1.day.ago)
      future = create_task(description: "Future", due_at: 1.day.from_now)

      assert_includes Corvid::Task.overdue, overdue
      refute_includes Corvid::Task.overdue, future
    end
  end

  test "unassigned scope" do
    with_tenant(TENANT) do
      unassigned = create_task(description: "No one")
      assigned = create_task(description: "Someone")
      assigned.assign_to!("pr_001")

      assert_includes Corvid::Task.unassigned, unassigned
      refute_includes Corvid::Task.unassigned, assigned
    end
  end

  test "for_assignee scope" do
    with_tenant(TENANT) do
      task = create_task
      task.assign_to!("pr_001")
      other = create_task(description: "Other")
      other.assign_to!("pr_002")

      assert_includes Corvid::Task.for_assignee("pr_001"), task
      refute_includes Corvid::Task.for_assignee("pr_001"), other
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

  # -- due_soon scope --------------------------------------------------------

  test "due_soon scope finds tasks due within window" do
    with_tenant(TENANT) do
      due_soon = create_task(description: "Due soon", due_at: 3.days.from_now)
      due_later = create_task(description: "Due later", due_at: 14.days.from_now)

      results = Corvid::Task.due_soon(7)
      assert_includes results, due_soon
      refute_includes results, due_later
    end
  end

  # -- Predicates -------------------------------------------------------------

  test "incomplete? returns true for pending and in_progress" do
    with_tenant(TENANT) do
      task = create_task
      assert task.incomplete?

      task.in_progress!
      assert task.incomplete?

      task.completed!
      refute task.incomplete?
    end
  end

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

  test "incomplete? returns false for cancelled tasks" do
    with_tenant(TENANT) do
      task = create_task
      task.cancelled!
      refute task.incomplete?
    end
  end

  # -- completed_at callback -------------------------------------------------

  test "sets completed_at when completing" do
    with_tenant(TENANT) do
      task = create_task
      task.completed!
      assert task.completed_at.present?
    end
  end

  # -- FHIR serialization ---------------------------------------------------

  test "fhir_status maps pending to requested" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :pending)
      assert_equal "requested", task.fhir_status
    end
  end

  test "fhir_status maps in_progress to in-progress" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :in_progress)
      assert_equal "in-progress", task.fhir_status
    end
  end

  test "fhir_status maps completed to completed" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :completed)
      assert_equal "completed", task.fhir_status
    end
  end

  test "fhir_status maps cancelled to cancelled" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :cancelled)
      assert_equal "cancelled", task.fhir_status
    end
  end

  test "fhir_status maps on_hold to on-hold" do
    with_tenant(TENANT) do
      task = Corvid::Task.new(status: :on_hold)
      assert_equal "on-hold", task.fhir_status
    end
  end

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
      task = create_task(taskable: referral)
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

  # -- FHIR parsing ----------------------------------------------------------

  test "from_fhir_attributes extracts status with reverse mapping" do
    with_tenant(TENANT) do
      fhir_resource = OpenStruct.new(
        status: "requested", intent: "order", description: "Test task"
      )
      attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
      assert_equal "pending", attrs[:status]
      assert_equal "Test task", attrs[:description]
    end
  end

  test "from_fhir_attributes extracts in-progress status" do
    with_tenant(TENANT) do
      fhir_resource = OpenStruct.new(status: "in-progress", intent: "order")
      attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
      assert_equal "in_progress", attrs[:status]
    end
  end

  test "from_fhir_attributes extracts priority" do
    with_tenant(TENANT) do
      fhir_resource = OpenStruct.new(
        status: "requested", intent: "order", priority: "urgent"
      )
      attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
      assert_equal "urgent", attrs[:priority]
    end
  end

  test "from_fhir_attributes extracts owner reference" do
    with_tenant(TENANT) do
      fhir_resource = OpenStruct.new(
        status: "requested", intent: "order",
        owner: OpenStruct.new(reference: "Practitioner/pr_101")
      )
      attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
      assert_equal "pr_101", attrs[:assignee_identifier]
    end
  end

  test "from_fhir_attributes parses executionPeriod end as due_at" do
    with_tenant(TENANT) do
      fhir_resource = OpenStruct.new(
        status: "requested", intent: "order",
        executionPeriod: OpenStruct.new(end: "2026-03-01T12:00:00Z")
      )
      attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
      assert_equal Date.parse("2026-03-01"), attrs[:due_at].to_date
    end
  end

  test "from_fhir_attributes handles missing owner" do
    with_tenant(TENANT) do
      fhir_resource = OpenStruct.new(status: "requested", intent: "order")
      attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
      assert_nil attrs[:assignee_identifier]
    end
  end

  test "from_fhir_attributes handles missing executionPeriod" do
    with_tenant(TENANT) do
      fhir_resource = OpenStruct.new(status: "requested", intent: "order")
      attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
      assert_nil attrs[:due_at]
    end
  end

  # -- Round trip -------------------------------------------------------------

  test "to_fhir round-trip preserves core data" do
    with_tenant(TENANT) do
      due = Date.parse("2026-03-01")
      task = create_task(
        description: "Follow up on lab results",
        priority: :urgent,
        due_at: due
      )
      task.assign_to!("pr_101")

      fhir = task.to_fhir
      fhir_struct = OpenStruct.new(
        status: fhir[:status],
        intent: fhir[:intent],
        description: fhir[:description],
        priority: fhir[:priority],
        owner: fhir[:owner] ? OpenStruct.new(reference: fhir[:owner][:reference]) : nil,
        executionPeriod: fhir[:executionPeriod] ? OpenStruct.new(end: fhir[:executionPeriod][:end]) : nil
      )

      attrs = Corvid::Task.from_fhir_attributes(fhir_struct)
      assert_equal "pending", attrs[:status]
      assert_equal "Follow up on lab results", attrs[:description]
      assert_equal "urgent", attrs[:priority]
      assert_equal "pr_101", attrs[:assignee_identifier]
      assert_equal due, attrs[:due_at].to_date
    end
  end

  test "to_fhir round-trip for all status values" do
    with_tenant(TENANT) do
      %w[pending in_progress completed cancelled on_hold].each do |status_val|
        task = Corvid::Task.new(status: status_val)
        fhir = task.to_fhir
        fhir_struct = OpenStruct.new(status: fhir[:status], intent: "order")
        attrs = Corvid::Task.from_fhir_attributes(fhir_struct)
        assert_equal status_val, attrs[:status],
          "Round-trip failed for status #{status_val}"
      end
    end
  end

  # -- Multi-tenancy ---------------------------------------------------------

  test "tasks are scoped to current tenant" do
    other_tenant = "tnt_task_other"
    task_in_tenant = nil
    task_outside = nil

    with_tenant(TENANT) do
      task_in_tenant = create_task(description: "My task")
    end

    with_tenant(other_tenant) do
      task_outside = create_task(description: "Other task")
    end

    with_tenant(TENANT) do
      visible = Corvid::Task.all
      assert_includes visible, task_in_tenant
      refute_includes visible, task_outside
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
