# frozen_string_literal: true

require "csv"
require "digest"
require "zlib"

module Corvid
  # Export and import the canonical CMS fee schedule data as a versioned
  # snapshot. The snapshot is the deploy artifact; the raw CMS source CSVs
  # are *not* needed at runtime once the snapshot is loaded.
  #
  # Format: gzipped CSV with a fixed header. One row per
  # (cpt_code, locality, effective_date) — exactly the natural key of
  # corvid_fee_schedule_entries.
  #
  # Determinism: same DB content produces the same snapshot bytes. Rows are
  # ordered by (effective_date, cpt_code, locality) so SHA256 is stable.
  module CmsSnapshot
    HEADERS = %w[
      cpt_code
      locality
      effective_date
      work_rvu
      pe_rvu
      mp_rvu
      work_gpci
      pe_gpci
      mp_gpci
      conversion_factor
    ].freeze

    DEFAULT_PATH = Pathname.new("db/seeds/cms_fee_schedules.csv.gz").freeze

    class << self
      # Stream the snapshot to an open IO. Writer is responsible for
      # gzipping if desired (use Zlib::GzipWriter wrapping the file IO).
      def export_csv(io)
        csv = CSV.new(io)
        csv << HEADERS
        rows_written = 0

        # Stream via PG COPY for speed. Falls back to find_each on
        # non-Postgres adapters for portability in tests.
        connection = Corvid::FeeScheduleEntry.connection
        if connection.adapter_name == "PostgreSQL"
          rows_written = copy_out(connection, csv)
        else
          Corvid::FeeScheduleEntry.unscoped
            .order(:effective_date, :cpt_code, :locality)
            .find_each(batch_size: 5000) do |e|
              csv << row_for(e)
              rows_written += 1
            end
        end

        rows_written
      end

      # Load a snapshot CSV (already-decompressed IO) into the DB. Uses
      # PG COPY for speed; truncates first so the load is idempotent.
      def import_csv(io)
        connection = Corvid::FeeScheduleEntry.connection
        connection.execute("TRUNCATE corvid_fee_schedule_entries")

        if connection.adapter_name == "PostgreSQL"
          copy_in(connection, io)
        else
          import_via_active_record(io)
        end
      end

      # SHA256 of an arbitrary IO, in hex. Used to record provenance of
      # the source RVU+GPCI files in CmsFeeScheduleRelease, and to verify
      # snapshot integrity.
      def checksum_io(io)
        digest = Digest::SHA256.new
        while (chunk = io.read(64 * 1024))
          digest.update(chunk)
        end
        digest.hexdigest
      end

      def parser_version
        # Pinned via the gem version + a git SHA when available so we can
        # tell which parser shaped a given snapshot. SHA discovered at
        # boot, not runtime, so failures here are silent.
        @parser_version ||= begin
          sha = `git -C #{Corvid::Engine.root} rev-parse --short HEAD 2>/dev/null`.chomp
          sha.empty? ? "unknown" : "#{Corvid::VERSION}+#{sha}"
        rescue
          Corvid::VERSION
        end
      end

      private

      def copy_out(connection, csv)
        sql = <<~SQL
          COPY (
            SELECT cpt_code, locality, effective_date,
                   work_rvu, pe_rvu, mp_rvu,
                   work_gpci, pe_gpci, mp_gpci,
                   conversion_factor
            FROM corvid_fee_schedule_entries
            ORDER BY effective_date, cpt_code, locality
          ) TO STDOUT WITH (FORMAT CSV, HEADER false)
        SQL

        rows = 0
        connection.raw_connection.copy_data(sql) do
          while (line = connection.raw_connection.get_copy_data)
            csv << CSV.parse_line(line)
            rows += 1
          end
        end
        rows
      end

      def copy_in(connection, io)
        # First line is header — strip and verify.
        header = io.gets&.chomp&.split(",")
        unless header == HEADERS
          raise ArgumentError, "snapshot header mismatch: expected #{HEADERS.inspect}, got #{header.inspect}"
        end

        # COPY does not populate Rails timestamps. Set transient defaults so
        # NOT NULL constraints are satisfied without baking NOW() into the
        # table schema permanently. Wrapped in begin/ensure so the defaults
        # are removed even if COPY raises.
        rows = 0
        connection.execute(<<~SQL)
          ALTER TABLE corvid_fee_schedule_entries
            ALTER COLUMN created_at SET DEFAULT NOW(),
            ALTER COLUMN updated_at SET DEFAULT NOW()
        SQL

        begin
          sql = <<~SQL
            COPY corvid_fee_schedule_entries (
              cpt_code, locality, effective_date,
              work_rvu, pe_rvu, mp_rvu,
              work_gpci, pe_gpci, mp_gpci,
              conversion_factor
            ) FROM STDIN WITH (FORMAT CSV)
          SQL

          connection.raw_connection.copy_data(sql) do
            io.each_line do |line|
              connection.raw_connection.put_copy_data(line)
              rows += 1
            end
          end
        ensure
          connection.execute(<<~SQL)
            ALTER TABLE corvid_fee_schedule_entries
              ALTER COLUMN created_at DROP DEFAULT,
              ALTER COLUMN updated_at DROP DEFAULT
          SQL
        end

        rows
      end

      def import_via_active_record(io)
        # Slow path for non-Postgres test adapters. Used by the engine's
        # CSV-roundtrip tests when running against SQLite, not in prod.
        csv = CSV.new(io, headers: true)
        rows = 0
        csv.each do |row|
          Corvid::FeeScheduleEntry.create!(
            cpt_code: row["cpt_code"],
            locality: row["locality"],
            effective_date: row["effective_date"],
            work_rvu: row["work_rvu"],
            pe_rvu: row["pe_rvu"],
            mp_rvu: row["mp_rvu"],
            work_gpci: row["work_gpci"],
            pe_gpci: row["pe_gpci"],
            mp_gpci: row["mp_gpci"],
            conversion_factor: row["conversion_factor"]
          )
          rows += 1
        end
        rows
      end

      def row_for(entry)
        [
          entry.cpt_code, entry.locality, entry.effective_date,
          entry.work_rvu, entry.pe_rvu, entry.mp_rvu,
          entry.work_gpci, entry.pe_gpci, entry.mp_gpci,
          entry.conversion_factor
        ]
      end
    end
  end
end
