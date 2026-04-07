# frozen_string_literal: true

require "rails/engine"
require "aasm"
require "ostruct"

module Corvid
  class Engine < ::Rails::Engine
    isolate_namespace Corvid

    # Append engine migrations to the host app's migration paths.
    initializer "corvid.append_migrations" do |app|
      config.paths["db/migrate"].expanded.each do |expanded_path|
        unless app.config.paths["db/migrate"].include?(expanded_path)
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end
  end
end
