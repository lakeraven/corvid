# frozen_string_literal: true

require "minitest/autorun"

# Guards the dummy app's checked-in schema.rb against silent corruption.
#
# Why this matters: on a fresh database `rails db:migrate` does NOT run the
# migrations. ActiveRecord::Tasks::DatabaseTasks#initialize_database sees an
# uninitialized database, loads db/schema.rb, and stamps every version at or
# below the file's `define(version:)` into schema_migrations. Only migrations
# newer than that version are then executed. CI builds its test database
# exactly that way, so schema.rb -- not db/migrate -- is what CI actually runs.
#
# The consequence is that a table which goes missing from schema.rb is never
# created in CI, and the matching migration is never re-run to fix it: its
# timestamp sits below the recorded version, so it is not "pending". Boot then
# dies in maintain_test_schema with PG::UndefinedTable when the model loads its
# columns -- a failure a long way from its cause.
#
# That is not hypothetical. json 3.x dropped positional-Hash parser options,
# which broke ActiveSupport::JSON.decode and therefore the schema dumper's
# rendering of jsonb column defaults. `db:migrate` auto-invokes `db:_dump`, so
# anyone who ran migrations with json 3.x installed silently rewrote the
# corvid_prc_eligibility_decisions table into a "Could not dump table" comment.
#
# These assertions are pure text checks: no Rails boot and no database, so they
# still report the real problem when the app itself can no longer boot.
class SchemaIntegrityTest < Minitest::Test
  ENGINE_ROOT = File.expand_path("../..", __dir__)
  SCHEMA_PATH = File.join(ENGINE_ROOT, "test/dummy/db/schema.rb")
  MIGRATION_GLOB = File.join(ENGINE_ROOT, "db/migrate/*.rb")

  def schema
    @schema ||= File.read(SCHEMA_PATH)
  end

  # The dumper swallows per-table exceptions and leaves a comment in place of
  # the table, so a broken dump looks like a plausible file. Catch the marker.
  def test_schema_has_no_failed_table_dumps
    failures = schema.scan(/^#\s*Could not dump table "([^"]+)".*$/).flatten

    assert_empty failures,
      "test/dummy/db/schema.rb contains failed table dumps for " \
      "#{failures.join(', ')}. The schema dumper raised while writing these " \
      "tables, so they are absent from the schema CI loads and every test " \
      "run will die at boot with PG::UndefinedTable. Do not commit this file: " \
      "fix the dumper error first (a jsonb default plus an incompatible json " \
      "gem is the known cause), then regenerate with `rails db:migrate`."
  end

  # Every table a migration creates has to survive into schema.rb, because a
  # migration older than the recorded schema version will never be replayed.
  def test_every_migrated_table_is_present_in_schema
    dumped = schema.scan(/^\s*create_table "([^"]+)"/).flatten

    missing = Dir[MIGRATION_GLOB].sort.flat_map { |path|
      File.read(path).scan(/^\s*create_table[( ]+[:"']([a-z0-9_]+)/).flatten
    }.uniq.reject { |table| dumped.include?(table) }

    assert_empty missing,
      "db/migrate creates #{missing.join(', ')} but test/dummy/db/schema.rb " \
      "does not define #{missing.one? ? 'it' : 'them'}. On a fresh database " \
      "db:migrate loads schema.rb and stamps the recorded version, so these " \
      "migrations will never run and the tables will never exist in CI. " \
      "Regenerate schema.rb from a full migration run."
  end
end
