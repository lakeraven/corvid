# frozen_string_literal: true

require "rails/engine"
require "aasm"
require "money-rails"
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

    # Money-rails defaults per ADR 0004. Every monetized model declares
    # `monetize ..., with_model_currency: :currency_iso` so cross-currency
    # arithmetic raises by default. Global default is USD; international
    # tenants set per-row currency_iso when those onboardings happen.
    initializer "corvid.money_rails" do
      MoneyRails.configure do |config|
        config.default_currency = :usd
        config.no_cents_if_whole = false
        config.symbol = false
        config.locale_backend = :i18n
      end
    end
  end
end
