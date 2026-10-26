# frozen_string_literal: true

require "csv"

module Corvid
  # Normalizes the CMS IPPS Final Rule **Wage Index Public Use File**
  # into the canonical `locality,base_rate,wage_index` shape that
  # `CmsIppsParser.parse_hospital_rates` (and the existing
  # `cms:ipps:import_hospital_rates` / `cms:ipps:fetch_release` rake
  # tasks) already consume. No new importer is needed — this only
  # produces a richer version of the same canonical file, with one row
  # per CBSA wage area instead of the NATIONAL-only row we've shipped
  # so far (#369 / parent #351).
  #
  # ## Source file
  #
  # CMS publishes the Wage Index PUF as part of each year's IPPS Final
  # Rule download (`fy{YEAR}-ipps-fr-wage-index-puf.zip`, linked from
  # the Final Rule home page's "Wage Index" section). The zip contains
  # several `.txt` files; this normalizer reads the **CBSA-level**
  # file (filename contains `cbsaoccmix`), which carries one row per
  # CMS wage area:
  #
  #   - 5-digit numeric codes for urban Core-Based Statistical Areas
  #     (and, for the largest metros, OMB Metropolitan Divisions —
  #     e.g. "35614" for the NY-Jersey City-White Plains division
  #     rather than the parent NYC CBSA).
  #   - 2-digit codes for each state's "rest of state" rural wage area.
  #
  # ## Wage index figure used
  #
  # The file carries both an "unadjusted" and an "occupational mix
  # adjusted" wage index per area. We use the **occupational-mix-
  # adjusted** figure (column header "CBSAGEO occmix wage index") —
  # this is the wage index CMS publishes as Table 2 in the Final Rule
  # and the one most commonly cited as "the" FY wage index for an
  # area. It does **not** include geographic reclassification, the
  # rural floor, the out-migration adjustment, or budget-neutrality
  # normalization — those are provider-specific adjustments layered on
  # top in CMS's actual payment calculation. Matches this codebase's
  # existing posture (see `PrcOverpaymentAnalyzer`'s docstring): a
  # screening-estimate wage index, not the fully-adjudicated one.
  # Reclassification-grade accuracy is out of scope here, same as IME/
  # DSH/outlier/capital are out of scope for the IPPS rate itself
  # (#320).
  #
  # ## File format quirks
  #
  # Tab-delimited, **CRLF** row separator, ISO-8859-1 encoded. The
  # header row's cells span multiple physical lines (CMS wraps long
  # header labels inside quoted multi-line CSV fields) — real CSV
  # parsing (not naive line-splitting) is required to read it
  # correctly; Ruby's CSV library handles it once `row_sep` is pinned
  # to `"\r\n"` (its default row-sep autodetection gets confused by
  # the bare `\n` characters embedded inside the quoted header cells).
  module CmsIppsWageIndexNormalizer
    LOCALITY_HEADER = "CBSAGEO"
    WAGE_INDEX_HEADER = "CBSAGEO occmix wage index"

    class MalformedFileError < StandardError; end

    def self.normalize(path)
      text = File.read(path, encoding: "ISO-8859-1")
                 .encode("UTF-8", invalid: :replace, undef: :replace)
      rows = CSV.parse(text, col_sep: "\t", row_sep: "\r\n")
      raise MalformedFileError, "wage index file has no header row" if rows.empty?

      header = rows.first
      cols = column_indexes(header)

      rows[1..].filter_map.with_index do |row, i|
        line_number = i + 2 # 1-indexed source line, header is line 1
        locality = row[cols[:locality]]&.strip
        wage_raw = row[cols[:wage_index]]&.strip
        next if locality.nil? || locality.empty?
        next if wage_raw.nil? || wage_raw.empty?

        { locality: locality, wage_index: parse_wage_index(wage_raw, locality: locality, line: line_number) }
      end
    end

    # Render the normalized per-CBSA rows as the canonical
    # `ipps_hospital_rates_FY{year}.csv` shape, including the NATIONAL
    # fallback row (wage_index 1.0, since it's the pre-wage-adjustment
    # national rate the analyzer already uses). `base_rate` is the
    # same national operating standardized amount used for the
    # NATIONAL row and every locality row — the wage index is what
    # varies by area; the base rate itself does not.
    #
    # Money stays exact (ADR 0004): `base_rate` is parsed as a
    # BigDecimal from its string form and written as fixed-point
    # dollars; a sub-cent or non-positive base rate raises instead of
    # being rounded or written. Wage indexes are written exactly as
    # CMS published them.
    def self.render(rows, base_rate:, release_label:)
      dollars = fixed_point_dollars(base_rate)
      body = CSV.generate do |csv|
        csv << %w[locality base_rate wage_index]
        csv << [ "NATIONAL", dollars, "1.0000" ]
        rows.each do |r|
          csv << [ r[:locality], dollars, BigDecimal(r[:wage_index].to_s).to_s("F") ]
        end
      end
      "# release_label: #{release_label}\n" + body
    end

    def self.fixed_point_dollars(raw)
      amount = BigDecimal(raw.to_s.strip)
      raise ArgumentError, "base_rate must be positive, got #{raw.inspect}" unless amount.finite? && amount.positive?
      raise ArgumentError, "base_rate has sub-cent precision, got #{raw.inspect}" unless amount.round(2) == amount

      whole, cents = amount.to_s("F").split(".")
      "#{whole}.#{cents.to_s.ljust(2, "0")}"
    end
    private_class_method :fixed_point_dollars

    def self.parse_wage_index(raw, locality:, line:)
      value = BigDecimal(raw.delete(","))
      raise ArgumentError unless value.finite? && value.positive?

      value
    rescue ArgumentError, TypeError
      raise MalformedFileError,
            "could not parse wage index=#{raw.inspect} as a positive number " \
            "for locality #{locality} at source line #{line}"
    end
    private_class_method :parse_wage_index

    def self.column_indexes(header_row)
      normalized = header_row.map { |h| h.to_s.strip.gsub(/\s+/, " ") }
      required = { locality: LOCALITY_HEADER, wage_index: WAGE_INDEX_HEADER }
      required.transform_values do |label|
        idx = normalized.index(label)
        raise MalformedFileError,
              "wage index file missing required column #{label.inspect}; " \
              "got: #{normalized.inspect}" if idx.nil?
        idx
      end
    end
    private_class_method :column_indexes
  end
end
