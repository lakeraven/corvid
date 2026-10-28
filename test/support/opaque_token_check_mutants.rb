# frozen_string_literal: true

# Shared malformed token strings that exercise CHECK-regex and OpaqueToken::FORMAT
# anchors (prefix length, Crockford alphabet, end anchor).
module OpaqueTokenCheckMutants
  VALID_ULID_BODY = "01HK8B7Z9XCQVG3F8N5K0R4MWB"
  FORBIDDEN_ULID_LETTERS = %w[I L O U].freeze

  module_function

  def malformed_opaque_token_anchors(prefix: "ab", body: VALID_ULID_BODY)
    valid = "#{prefix}_#{body}"
    anchors = [
      "free text #{valid}",
      "abcde_#{body}",
      "#{prefix.upcase}_#{body}",
      "#{prefix}_#{body.downcase}",
      "x_#{body}",
      "#{prefix}_#{body[0, 25]}",
      "#{valid}X"
    ]
    FORBIDDEN_ULID_LETTERS.each do |letter|
      anchors << "#{prefix}_#{body.sub(/.$/, letter)}"
    end
    anchors
  end

  def valid_clm_opaque_claim_identifier(body: VALID_ULID_BODY)
    "clm_#{body}"
  end

  def malformed_clm_claim_identifiers(body: VALID_ULID_BODY)
    valid = "CLM_#{body}"
    anchors = [
      "CLM_#{body[0, 25]}",
      "CLM-#{body}",
      "123456789",
      "clm_example_1",
      "#{valid}X"
    ]
    FORBIDDEN_ULID_LETTERS.each do |letter|
      anchors << valid.sub(/.$/, letter)
    end
    anchors
  end

  def postgres_pattern_to_ruby(pattern)
    inner = pattern.sub(/\A\^/, "").sub(/\$\z/, "")
    /\A#{inner}\z/
  end
end
