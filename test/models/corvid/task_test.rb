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
