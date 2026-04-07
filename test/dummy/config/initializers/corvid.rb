# frozen_string_literal: true

Corvid.configure do |c|
  c.adapter = Corvid::Adapters::MockAdapter.new
end
