# frozen_string_literal: true

require "csv"

module Corvid
  # Parses CMS Physician Fee Schedule files (PPRRVU and GPCI) into structured
  # data. CMS file conventions drift over time — this parser handles two known
  # format generations:
  #
  # GPCI (Geographic Practice Cost Indices):
  #   - 2007–2020: locality at column index 1 (carrier, locality, name, work, pe, mp)
  #   - 2021+:     locality at column index 2 (carrier, state, locality, name, work, pe, mp)
  #
  # PPRRVU (RVU file naming):
  #   - 2007–2025: PPRRVU{yy}*.csv (2-digit year)
  #   - 2026+:     PPRRVU{year}*.csv (4-digit year)
  module CmsFeeScheduleParser
    # CMS conversion factors by year (from Federal Register).
    # Published annually — hardcoded for reliability.
    CONVERSION_FACTORS = {
      2007 => 37.8975, 2008 => 38.0870, 2009 => 36.0666,
      2010 => 36.0846, 2011 => 33.9764, 2012 => 34.0230,
      2013 => 34.0230, 2014 => 35.8228, 2015 => 35.7547,
      2016 => 35.8043, 2017 => 35.8887, 2018 => 35.9996,
      2019 => 36.0391, 2020 => 36.0896, 2021 => 34.8931,
      2022 => 34.6062, 2023 => 33.0607, 2024 => 32.7442,
      2025 => 32.3465, 2026 => 32.7400
    }.freeze
    DEFAULT_CONVERSION_FACTOR = 32.74

    class << self
      def conversion_factor(year)
        CONVERSION_FACTORS[year] || DEFAULT_CONVERSION_FACTOR
      end

      # Returns Hash of { locality_code => { work:, pe:, mp: } }.
      # Detects pre-2021 vs 2021+ layout by checking which column holds a
      # 2-digit locality code on the first plausible data row.
      def parse_gpcis(file)
        gpcis = {}
        locality_col = nil

        CSV.foreach(file, encoding: "iso-8859-1:utf-8", liberal_parsing: true) do |row|
          locality_col ||= detect_locality_column(row)
          next unless locality_col

          locality = row[locality_col]&.strip
          next unless locality&.match?(/^\d{2}$/)

          # GPCI columns sit immediately after locality + name (one column gap).
          # Pre-2021: locality=1, name=2, work=3, pe=4, mp=5
          # 2021+:    locality=2, name=3, work=4, pe=5, mp=6
          base = locality_col + 2
          work = row[base]&.to_f || 1.0
          pe   = row[base + 1]&.to_f || 1.0
          mp   = row[base + 2]&.to_f || 1.0

          gpcis[locality] = { work: work, pe: pe, mp: mp }
        end

        gpcis
      end

      # Yields [cpt_code, work_rvu, pe_rvu, mp_rvu] for each priced row.
      # Skips header rows and rows where work and pe are both zero.
      def parse_rvus(file)
        header_found = false
        hcpcs_col = nil
        work_col = nil
        pe_col = nil
        mp_col = nil

        CSV.foreach(file, encoding: "iso-8859-1:utf-8", liberal_parsing: true) do |row|
          if !header_found && row.any? { |c| c&.strip == "HCPCS" }
            header_found = true
            row.each_with_index do |col, i|
              c = col&.strip&.upcase
              hcpcs_col = i if c == "HCPCS"
              work_col = i if c == "WORK" || (c&.include?("WORK") && c&.include?("RVU"))
              mp_col = i if c == "MP" || (c&.start_with?("MP") && c&.include?("RVU"))
            end
            work_col ||= 5
            pe_col = work_col + 1
            mp_col ||= work_col + 9
            next
          end
          next unless header_found

          cpt = row[hcpcs_col || 0]&.strip
          next if cpt.nil? || cpt.empty? || !cpt.match?(/^[0-9A-Z]/)

          work = row[work_col]&.to_f || 0
          pe   = row[pe_col]&.to_f || 0
          mp   = row[mp_col]&.to_f || 0

          next if work.zero? && pe.zero?

          yield cpt, work, pe, mp
        end
      end

      # Find the PPRRVU file for a given year. CMS naming changed from
      # 2-digit year (PPRRVU25_JAN.csv) to 4-digit year (PPRRVU2026_Jan_nonQPP.csv)
      # in 2026. Match files where the year token sits at a clean boundary
      # (followed by `.`, `_`, or end-of-name) so a 2-digit query like 26
      # does not substring-match a 4-digit name like PPRRVU2026_*. Sort
      # deterministically; prefer nonQPP > JAN > first.
      def find_rvu_file(base_dir, year)
        # Character-class glob for cross-platform parity. macOS HFS+ is
        # case-insensitive at the filesystem level; Linux ext4 is not.
        # FNM_CASEFOLD on Dir.glob is unreliable across Ruby versions, so
        # the pattern itself spells out both cases.
        candidates = Dir.glob(File.join(base_dir, "[Pp][Pp][Rr][Rr][Vv][Uu]*.csv"))
                        .select { |f| year_token_match?(File.basename(f), "PPRRVU", year) }
                        .uniq.sort
        return nil if candidates.empty?

        candidates.find { |f| f =~ /nonQPP/i } ||
          candidates.find { |f| f =~ /jan/i } ||
          candidates.first
      end

      # Find the GPCI file for a given year. Require a year-matching token
      # (4-digit or 2-digit) at a clean boundary — never fall back to any
      # GPCI-ish file, and never substring-match across decades. Sort
      # deterministically.
      def find_gpci_file(base_dir, year)
        # Character-class glob — real CMS files include both GPCI09.csv
        # and gpci10.csv depending on year. Spelled out for cross-version
        # / cross-platform parity (FNM_CASEFOLD unreliable on Dir.glob).
        candidates = Dir.glob(File.join(base_dir, "*[Gg][Pp][Cc][Ii]*.csv"))
                        .select { |f| gpci_year_match?(File.basename(f), year) }
                        .uniq.sort
        candidates.first
      end

      private

      # Match basenames where the year (4-digit or 2-digit) appears as a
      # delimited token directly after `prefix`. Boundary delimiters: `.`
      # or `_`. End-of-name (i.e. immediately before `.csv`) also counts.
      def year_token_match?(basename, prefix, year)
        yy = year.to_s[-2..]
        basename.match?(/\A#{Regexp.escape(prefix)}(?:#{year}|#{yy})(?:[._]|\.csv\z)/i)
      end

      # GPCI naming is chaotic across years — five known shapes:
      #   GPCI07.csv, GPCI2018.csv, gpci10.csv             (year right after GPCI)
      #   GPCI_2011.csv                                    (underscore separator)
      #   CY2015_GPCIs.csv                                 (year before GPCI)
      #   CY 2014 GPCI _12172013.csv                       (spaces, year before GPCI)
      # Match if the filename contains "GPCI" *and* contains the year (4-digit
      # or 2-digit) anywhere at a digit boundary, so it cannot substring-match
      # within an unrelated number like a revision date.
      def gpci_year_match?(basename, year)
        yy = year.to_s[-2..]
        return false unless basename =~ /GPCI/i
        basename.match?(/(?:\A|[^0-9])(?:#{year}|#{yy})(?:[^0-9]|\z)/)
      end

      # On the first row whose pre-name column holds a 2-digit locality code,
      # return that column index. This adapts to CMS adding the State column
      # in 2021. Returns nil on rows that don't look like data.
      def detect_locality_column(row)
        return nil unless row.is_a?(Array)
        return 1 if row[1]&.strip&.match?(/^\d{2}$/)
        return 2 if row[2]&.strip&.match?(/^\d{2}$/) && row[1]&.strip&.match?(/^[A-Z]{2}$/)

        nil
      end
    end
  end
end
