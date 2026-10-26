# frozen_string_literal: true

module Corvid
  module Demo
    # The demo:* rake tasks delete and re-seed rows, and they own the
    # development database. The bin/demo-* entry points refuse any other
    # RAILS_ENV (#565), but the tasks can also be run directly, so each task
    # checks again before it touches the database. Same wording as bin/demo-*.
    module EnvironmentGuard
      module_function

      def ensure_development!(task_name)
        return if Rails.env.development?

        abort "#{task_name}: refusing to run with RAILS_ENV=#{Rails.env}; the demos use development"
      end
    end
  end
end
