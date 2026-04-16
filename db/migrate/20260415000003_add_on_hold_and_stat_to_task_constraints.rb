# frozen_string_literal: true

class AddOnHoldAndStatToTaskConstraints < ActiveRecord::Migration[8.1]
  TASK_STATUSES = %w[pending in_progress completed cancelled on_hold].freeze
  TASK_PRIORITIES = %w[routine urgent asap stat].freeze

  def up
    remove_check_constraint :corvid_tasks, name: "corvid_tasks_status_check"
    add_check_constraint :corvid_tasks,
                         "status IN (#{TASK_STATUSES.map { |s| "'#{s}'" }.join(',')})",
                         name: "corvid_tasks_status_check"

    remove_check_constraint :corvid_tasks, name: "corvid_tasks_priority_check"
    add_check_constraint :corvid_tasks,
                         "priority IN (#{TASK_PRIORITIES.map { |s| "'#{s}'" }.join(',')})",
                         name: "corvid_tasks_priority_check"
  end

  def down
    old_statuses = TASK_STATUSES - %w[on_hold]
    old_priorities = TASK_PRIORITIES - %w[stat]

    execute "UPDATE corvid_tasks SET status = 'pending' WHERE status = 'on_hold'"

    remove_check_constraint :corvid_tasks, name: "corvid_tasks_status_check"
    add_check_constraint :corvid_tasks,
                         "status IN (#{old_statuses.map { |s| "'#{s}'" }.join(',')})",
                         name: "corvid_tasks_status_check"

    execute "UPDATE corvid_tasks SET priority = 'asap' WHERE priority = 'stat'"

    remove_check_constraint :corvid_tasks, name: "corvid_tasks_priority_check"
    add_check_constraint :corvid_tasks,
                         "priority IN (#{old_priorities.map { |s| "'#{s}'" }.join(',')})",
                         name: "corvid_tasks_priority_check"
  end
end
