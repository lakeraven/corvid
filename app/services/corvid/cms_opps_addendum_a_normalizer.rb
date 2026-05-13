# frozen_string_literal: true

require "csv"

module Corvid
  # Normalizes a CMS OPPS Addendum A CSV (or quarterly Web Addendum A
  # release) into the canonical `apc_code,relative_weight` shape that
  # CmsOppsParser consumes.
  #
  # CMS Addendum A is published per quarter (typically January as the
  # Final Rule snapshot) as a zip containing both an xlsx and a CSV.
  # We read the CSV. Layout:
  #
  #   - Two title rows at top (rule version, copayment note)
  #   - Header row: APC, Group Title, SI, Relative Weight, Payment Rate, ...
  #   - ~1000 data rows; ~250 have a Relative Weight (status indicators
  #     S, T, V, J1, J2, R, U, P — the OPPS-PPS-priced classes).
  #     The rest are drug pass-throughs (G, K) and other categories
  #     that don't enter the weight × CF × wage_index formula.
  #
  # The file ships in ISO-8859-1 (special characters in some drug
  # names) so we re-encode to UTF-8 on read.
  #
  # Columns are resolved by header name (not position) so a quarterly
  # variant that adds or reorders columns doesn't silently misread the
  # weight. Numeric parsing is strict — a malformed weight ("12O.34")
  # raises MalformedFileError rather than silently becoming 12.0 via
  # String#to_f.
  module CmsOppsAddendumANormalizer
    HEADER_MARKER = "APC"

    # Status indicators that get paid via the OPPS APC formula.
    # Other rows (drug pass-throughs, contractor-priced, etc.) have
    # no relative weight and are skipped.
    WEIGHTED_STATUS_INDICATORS = %w[J1 J2 S S1 T V R U P].freeze

    # Header labels we look up. Names are compared case-insensitively
    # after stripping; CMS sometimes capitalizes inconsistently across
    # quarterly publications.
    APC_HEADER = "APC"
    SI_HEADER = "SI"
    WEIGHT_HEADER = "Relative Weight"

    class MalformedFileError < StandardError; end

    def self.normalize(addendum_a_path)
      text = File.read(addendum_a_path, encoding: "ISO-8859-1")
                 .encode("UTF-8", invalid: :replace, undef: :replace)
      rows = CSV.parse(text, liberal_parsing: true)

      header_idx = rows.index { |r| r[0]&.strip == HEADER_MARKER }
      raise MalformedFileError, "Addendum A CSV missing APC header row" if header_idx.nil?

      cols = column_indexes(rows[header_idx])

      rows[(header_idx + 1)..].filter_map.with_index do |row, i|
        line_number = header_idx + 2 + i # 1-indexed source line
        apc = row[cols[:apc]]&.strip
        si = row[cols[:si]]&.strip
        weight_raw = row[cols[:weight]]&.strip
        next if apc.nil? || apc.empty?
        next if weight_raw.nil? || weight_raw.empty?
        next unless WEIGHTED_STATUS_INDICATORS.include?(si)

        weight = parse_weight(weight_raw, apc: apc, line: line_number)
        next unless weight.positive?
        { apc_code: apc, relative_weight: weight }
      end
    end

    # Render the normalized rows as the canonical CSV string consumed
    # by CmsOppsParser + the cms:opps:fetch_release rake task. First
    # line is a `# release_label:` marker so the fetch-from-release
    # path can read provenance directly off the file.
    def self.render(rows, release_label:)
      body = CSV.generate do |csv|
        csv << %w[apc_code relative_weight]
        rows.each { |r| csv << [ r[:apc_code], format("%.4f", r[:relative_weight]) ] }
      end
      "# release_label: #{release_label}\n" + body
    end

    # Strict numeric parse. Permissive String#to_f silently converts
    # "12O.34" to 12.0 (letter O looks like a zero) and non-numeric
    # text to 0.0 — both produce a plausible-looking but wrong APC
    # weight. Kernel#Float raises on malformed input; we surface that
    # as MalformedFileError with row context.
    def self.parse_weight(raw, apc:, line:)
      Float(raw.delete(","))
    rescue ArgumentError, TypeError
      raise MalformedFileError,
            "could not parse relative_weight=#{raw.inspect} as numeric " \
            "for APC #{apc} at source line #{line}"
    end

    def self.column_indexes(header_row)
      normalized = header_row.map { |h| h.to_s.strip.downcase }
      required = {
        apc: APC_HEADER, si: SI_HEADER, weight: WEIGHT_HEADER
      }
      required.transform_values do |label|
        idx = normalized.index(label.downcase)
        raise MalformedFileError,
              "Addendum A header missing required column #{label.inspect}; " \
              "got: #{header_row.inspect}" if idx.nil?
        idx
      end
    end
  end
end
