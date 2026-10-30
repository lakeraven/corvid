# frozen_string_literal: true

module Corvid
  module Rcm
    # Shared blank check for claim identifiers, edit codes and descriptions,
    # and the fixture client's billing-provider NPI.
    #
    # Nil is blank. Anything else is read with `to_s` and is blank when
    # nothing remains after Unicode whitespace is removed: `[[:space:]]`
    # (ASCII space and Unicode spaces such as U+00A0 and U+2003) plus the
    # zero-width characters U+200B, U+200C, U+200D, U+2060, and U+FEFF.
    # The original text is not rewritten.
    module Blank
      BLANK_TEXT = /\A[[:space:]\u200B\u200C\u200D\u2060\uFEFF]*\z/
      private_constant :BLANK_TEXT

      module_function

      def blank?(value)
        value.nil? || BLANK_TEXT.match?(value.to_s)
      end
    end
  end
end
