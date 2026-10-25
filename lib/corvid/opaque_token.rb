# frozen_string_literal: true

module Corvid
  # Prefixed ULID vault tokens. ADR 0003 §4: the engine stores tokens the
  # vault issues and does not generate them. Crockford base32 omits I, L, O, U.
  module OpaqueToken
    # ADR 0003 §4.
    FORMAT = /\A[a-z]{2,4}_[0-9A-HJKMNP-TV-Z]{26}\z/

    def self.valid?(value)
      value.is_a?(String) && FORMAT.match?(value)
    end
  end
end
