# frozen_string_literal: true

module Corvid
  # Prefixed ULID vault tokens. ADR 0003 §4: the engine stores these and
  # does not generate them. Nothing in this codebase generates pt_ or pr_.
  # MockAdapter, the reference vault adapter, generates rf_ in
  # create_referral and the store_text prefixes. Crockford base32 omits
  # I, L, O, and U; FORMAT requires that uppercase body.
  module OpaqueToken
    # ADR 0003 §4.
    FORMAT = /\A[a-z]{2,4}_[0-9A-HJKMNP-TV-Z]{26}\z/

    def self.valid?(value)
      value.is_a?(String) && FORMAT.match?(value)
    end
  end
end
