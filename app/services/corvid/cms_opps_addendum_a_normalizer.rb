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
  #     S, T, V, J1, J2, R, U, P, S1 — the OPPS-PPS-priced classes).
  #     The rest are drug pass-throughs (G, K) and other categories
  #     that don't enter the weight × CF × wage_index formula.
  #
  # The file ships in ISO-8859-1 (special characters in some drug
  # names) so we re-encode to UTF-8 on read.
  module CmsOppsAddendumANormalizer
    HEADER_MARKER = "APC"

    # Status indicators that get paid via the OPPS APC formula.
    # Other rows (drug pass-throughs, contractor-priced, etc.) have
    # no relative weight and are skipped.
    WEIGHTED_STATUS_INDICATORS = %w[J1 J2 S S1 T V R U P].freeze

    def self.normalize(addendum_a_path)
      text = File.read(addendum_a_path, encoding: "ISO-8859-1")
                 .encode("UTF-8", invalid: :replace, undef: :replace)
      rows = CSV.parse(text, liberal_parsing: true)

      header_idx = rows.index { |r| r[0]&.strip == HEADER_MARKER }
      raise ArgumentError, "Addendum A CSV missing APC header row" if header_idx.nil?

      rows[(header_idx + 1)..].filter_map do |row|
        apc = row[0]&.strip
        si = row[2]&.strip
        weight_raw = row[3]&.strip
        next if apc.nil? || apc.empty?
        next if weight_raw.nil? || weight_raw.empty?
        next unless WEIGHTED_STATUS_INDICATORS.include?(si)

        weight = weight_raw.delete(",").to_f
        next unless weight.positive?
        { apc_code: apc, relative_weight: weight }
      end
    end

    # Render the normalized rows as the canonical CSV string consumed
    # by CmsOppsParser + the cms:opps:fetch_release rake task. First
    # line is a `# release_label:` marker so the fetch-from-release
    # path can read provenance directly off the file.
    def self.render(rows, release_label:)
      CSV.generate do |csv|
        # CSV.generate doesn't write comment lines; prepend manually
      end.then do |body|
        marker = "# release_label: #{release_label}\n"
        marker + CSV.generate do |csv|
          csv << %w[apc_code relative_weight]
          rows.each { |r| csv << [ r[:apc_code], format("%.4f", r[:relative_weight]) ] }
        end
      end
    end
  end
end
