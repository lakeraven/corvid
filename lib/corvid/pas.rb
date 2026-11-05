# frozen_string_literal: true

require "corvid/configuration"
require "corvid/pas/request_bundle"

module Corvid
  # Prior authorization (Da Vinci PAS).
  #
  # A request bundle is read for one parse and then discarded. Nothing from
  # it is cached or logged (ADR 0003).
  module Pas
  end
end
