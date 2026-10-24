require "test_helper"
require "yaml"

module Corvid
  # Enforces the acceptance criterion in docs/adr/0003-phi-tokenization.md:
  # "A corvid database dump, viewed without vault access, must reveal no PHI."
  #
  # DEFAULT-DENY, and that is the whole design. The first version of this guard
  # matched column NAMES against a list of PHI-ish words, which is the wrong net
  # for this claim: the claim is about what a column can HOLD, and the columns
  # that can hold free PHI are exactly the string/text/jsonb/binary ones. A
  # name-based net passed `subscriber`, `guarantor`, `pt_full`, a jsonb called
  # `clinical_summary` and a text called `progress_note` — all verified by probe.
  #
  # So: every column is a violation unless it is permitted by TYPE or by an
  # explicit naming convention, or disclosed in docs/phi-column-exceptions.yml.
  # Adding a column that can hold PHI now fails CI by default, and the way to
  # ship it is to disclose it — not to think of a name the regex misses.
  class PhiSchemaGuardTest < ActiveSupport::TestCase
    # Engine root, NOT Rails.root. In an engine's suite Rails.root is the dummy
    # app (test/dummy), so Rails.root.join("docs") resolves to a path that does
    # not exist, exceptions load empty, and every entry fails as though new.
    EXCEPTIONS_FILE = Corvid::Engine.root.join("docs", "phi-column-exceptions.yml")

    # Rails' own bookkeeping, not ours.
    INFRA_TABLES = %w[ar_internal_metadata schema_migrations].freeze

    # Public CMS reference data: rates, weights, localities, crosswalks. Not
    # patient-linked, so a CPT or DRG code here is a published fact rather than
    # a clinical fact about a person.
    #
    # EXACT names, never prefixes. The previous version matched with
    # `start_with?`, which meant a table called `corvid_cah_patient_surveys`
    # would inherit the `corvid_cah` exemption and hide a `patient_name` column
    # (verified by probe). It also listed 14 names of which 8 were not real
    # tables — the list "worked" only because 4 stubs happened to prefix-match.
    #
    # corvid_fmap_rules is the same kind of table: the statutory FMAP rule
    # set, global (no tenant), loaded from lib/corvid/data/fmap_rules.yml,
    # with no column that links a row to a person or an encounter.
    REFERENCE_TABLES = %w[
      corvid_asc_conversion_factors
      corvid_asc_facilities
      corvid_asc_hcpcs_rates
      corvid_cah_facilities
      corvid_cms_fee_schedule_releases
      corvid_fee_schedule_entries
      corvid_fmap_rules
      corvid_ipps_drg_weights
      corvid_ipps_hospital_rates
      corvid_npi_ccn_crosswalks
      corvid_opps_apc_weights
      corvid_opps_conversion_factors
      corvid_zip_localities
    ].freeze

    # Identifier words that are a violation whatever their TYPE. This layer
    # runs BEFORE any type or convention permit, because the default-deny
    # rewrite introduced a regression the name-based first version did not
    # have: an RPMS DFN is an integer IEN and an SSN fits in a bigint, so
    # `ssn:bigint`, `patient_dfn:integer` and `mrn:integer` were permitted by
    # SAFE_TYPES (verified by probe). Capacity needs default-deny; identifiers
    # need name-deny. Two nets, not one.
    IDENTIFIER_WORDS = /ssn|\bdfn\b|mrn|dob|birth|member|policy|\bnpi\b|subscriber|guarantor/.freeze

    # Types that cannot hold free text, so cannot hold narrative PHI. A number
    # or a boolean can still be identifying in combination, which is the host
    # responsibility ADR 0003 section 3 documents — it is not what this guard
    # is for.
    SAFE_TYPES = %i[integer bigint decimal float boolean].freeze

    # Column names permitted DESPITE being a text-ish type, each with the reason
    # it is safe. Type-gated: the previous version applied these by name alone,
    # so `patient_name_identifier` and `birth_date_at` were exempted by the
    # `_identifier` and `_at` rules (verified by probe).
    def permitted_by_convention?(name, type, table)
      case
      # Rails keys are integer/bigint/uuid. A STRING `_id` is an external
      # identifier wearing a Rails suffix — `vendor_id`, `obligation_id` and
      # `payment_id` are all strings on the two most sensitive tables, and the
      # blanket permit hid them from the disclosure file (verified by probe).
      when name == "id" || name.end_with?("_id")
        %i[integer bigint uuid].include?(type)
      when name.end_with?("_token")                    then %i[string text].include?(type)
      when name.end_with?("_identifier")               then type == :string
      when name.end_with?("_at")                       then type == :datetime
      when name.end_with?("_cents")                    then %i[integer bigint].include?(type)
      when name == "currency_iso"                      then type == :string
      when ENUM_COLUMNS.include?(name)
        type == :string && bounded?(table, name)
      when PROVENANCE_COLUMNS[table]&.include?(name)   then type == :string
      when PROVENANCE_JSONB_COLUMNS[table]&.include?(name) then type == :jsonb
      when polymorphic_type_column?(name, type, table) then true
      else false
      end
    end

    # An enum name is only safe if something actually bounds the values. When
    # this was written, 9 of the then 21 names in ENUM_COLUMNS had no check
    # constraint on some table that uses them, and corvid_cases.closure_reason has no constraint, no inclusion validation
    # and no writer anywhere — an unbounded string whose name is "reason",
    # which ADR 0003 section 1 lists among free text that is never stored.
    #
    # The constraint must confine THIS column to a value list — Postgres
    # stores `col IN (...)` as `col::text = ANY (ARRAY[...])`. Mentioning the
    # column is not enough: a pairing check or an IS NULL clause bounds
    # nothing, and `group` must not ride on a constraint for
    # `eligibility_group`.
    def bounded?(table, column)
      constraints = ActiveRecord::Base.connection.check_constraints(table)
      constraints.any? { |c| confines_to_value_list?(c.expression.to_s, column) }
    rescue NotImplementedError
      false
    end

    # The cast is matched as a type name, not as any run of words, so
    # "status::text NOT IN (...)" cannot pass as "status::text ... IN (".
    def confines_to_value_list?(expression, column)
      cast = /(?:::(?:text|character varying|varchar))?/
      expression.match?(/(?<![\w"])"?#{Regexp.escape(column)}"?#{cast}\s*(?:=\s*ANY\s*\(|IN\s*\()/i)
    end

    # Rails polymorphic partner: a `*_type` string that has a matching `*_id`
    # column on the same table holds a CLASS NAME, not data. Detected as a pair
    # rather than permitted by suffix, because `transaction_type`,
    # `provider_type` and `claim_type` are enums and `program_type` is workflow
    # state — a blanket `_type` permit would wave all of them through.
    def polymorphic_type_column?(name, type, table)
      return false unless type == :string && name.end_with?("_type")

      partner = "#{name.delete_suffix('_type')}_id"
      ActiveRecord::Base.connection.columns(table).any? { |c| c.name == partner }
    end

    # Workflow enums, plus api_name — which is an API's name, not a person's,
    # and is check-constrained to four values in the schema (so its capacity is
    # bounded, which is what default-deny actually cares about).
    #
    # Stored as strings by ADR 0003 section 3 ("Status,
    # priority, decision codes — stored as enum strings. Not PHI alone.").
    # Narrow and explicit: a text column called `role` must not ride in on this
    # (verified by probe), hence the type gate above.
    ENUM_COLUMNS = %w[
      status lifecycle_status priority program_type current_activity
      closure_reason decision enrollment_status resource_type role
      priority_system claim_type direction payment_system
      provider_confidence recovery_confidence decision_method
      transaction_type provider_type outcome
      api_name
      eligibility_group eligibility_group_source source
      category best_available_category coverage_group authority_type
      received_through_basis determination_reason
    ].freeze

    # Software and reference-data provenance, not patient data: which version
    # of the analyzer ran, which CMS release the rate came from, which workflow
    # milestone a task belongs to, and a digest. Named explicitly rather than
    # pattern-matched, so adding one is a reviewed line of code.
    # Scoped to the tables that own them: a `rate_source` on corvid_cases
    # would be something else entirely (verified by probe).
    #
    # verification_snapshot_key_version names the host key the snapshot HMAC
    # was taken under (ADR 0008): host configuration. The model caps it at 64
    # characters; SnapshotFingerprint, its only writer, also restricts it to
    # printable ASCII, but the model does not. On an FMAP determination, rule_key must name a rule of
    # the global corvid_fmap_rules table in force on the date of service, or
    # be blank when undetermined — the model checks both whenever the decided
    # fields are written. (best_available_rule_key and jurisdiction on the
    # same row are NOT validated that way, so they are disclosed instead.)
    PROVENANCE_COLUMNS = {
      "corvid_prc_overpayment_analyses" => %w[analyzer_version rate_source rate_source_release],
      "corvid_cms_fee_schedule_releases" => %w[cms_release_tag],
      "corvid_tasks" => %w[milestone_key],
      "corvid_prc_eligibility_decisions" => %w[verification_snapshot_hash verification_snapshot_key_version],
      "corvid_fmap_determinations" => %w[rule_key]
    }.freeze

    # Provenance held as jsonb. rule_citations is the applied rule's
    # statutory citation; the model requires it to equal
    # [rule.statutory_citation] whenever the decided fields are written, so
    # it can only hold text copied from the shipped rule set.
    PROVENANCE_JSONB_COLUMNS = {
      "corvid_fmap_determinations" => %w[rule_citations]
    }.freeze

    # Workforce tenure, not a patient's dates. A care-team member is a
    # practitioner_identifier (an opaque token per ADR 0001), so these two
    # dates say when a practitioner joined and left a team. Permitted here
    # rather than disclosed as an exception, because they are not patient data
    # and listing non-issues in the disclosure file overstates the problem.
    PERMITTED_WORKFORCE_DATES = [
      %w[corvid_care_team_members start_date],
      %w[corvid_care_team_members end_date]
    ].freeze

    # A facility's billing authority, not a patient's: corvid_facility_authorities
    # rows carry a tenant, a facility token, an authority type and the
    # period the authority was held, with no column that links them to a
    # person or an encounter. These dates are when a contract or compact was
    # in force. Permitted for the same reason as the workforce dates. The
    # table's two free strings (four_walls_exception_basis, service_area) are
    # NOT permitted: nothing bounds them, so they are disclosed instead.
    #
    # corvid_fee_schedules is the same kind of row: a tenant's sliding-fee
    # schedule (tiers already tokenized), with no person or encounter column.
    # Its validity dates are permitted; its name and program strings are
    # unbounded and disclosed.
    PERMITTED_FACILITY_COLUMNS = [
      %w[corvid_facility_authorities effective_on],
      %w[corvid_facility_authorities expires_on],
      %w[corvid_fee_schedules effective_date],
      %w[corvid_fee_schedules end_date]
    ].freeze

    # Always a violation, regardless of what the exceptions file says. These two
    # columns were dropped by this change; listing them means the drop cannot be
    # quietly undone by a later migration plus a yml entry.
    HARD_FAILURES = [
      %w[corvid_cases patient_name_cached],
      %w[corvid_cases patient_dob_cached]
    ].freeze

    VALID_CLASSIFICATIONS = %w[patient_phi accepted_workflow_date needs_decision unclassified].freeze

    def test_no_undisclosed_phi_capable_columns
      exceptions = load_exceptions
      violations = []
      tables_scanned = 0
      columns_scanned = 0

      # ALL tables, not just corvid_*. engine.rb appends this engine's
      # db/migrate to the host's migration paths, so an engine migration can
      # create a table with any name at all in a host database — a `patients`
      # table with `full_name` was invisible to the corvid_-only scan (verified
      # by probe). The dummy database has no non-corvid tables, so scanning
      # everything costs nothing and closes the hole.
      ActiveRecord::Base.connection.tables.each do |table|
        next if INFRA_TABLES.include?(table)
        next if REFERENCE_TABLES.include?(table)

        tables_scanned += 1

        ActiveRecord::Base.connection.columns(table).each do |column|
          columns_scanned += 1
          name = column.name
          type = column.type

          hard = HARD_FAILURES.include?([ table, name ])

          # Name-deny, but NOT over the tokenization convention: `policy_token`
          # exists precisely BECAUSE policy data is tokenized, so flagging it
          # for containing "policy" inverts ADR 0003. The convention permits
          # are the ADR's own contract and come first; name-deny then catches
          # identifier words on everything else, whatever the type.
          identifier_name = name.match?(IDENTIFIER_WORDS) &&
                            !name.end_with?("_token", "_identifier")

          unless hard || identifier_name
            next if SAFE_TYPES.include?(type)
            next if permitted_by_convention?(name, type, table)
            next if PERMITTED_WORKFORCE_DATES.include?([ table, name ])
            next if PERMITTED_FACILITY_COLUMNS.include?([ table, name ])
            next if exceptions[table]&.include?(name)
          end

          violations << {
            table: table,
            column: name,
            type: type,
            reason: hipaa_category(name, type),
            hard: hard
          }
        end
      end

      if violations.any?
        flunk build_message(violations)
      end

      # A scan that examined nothing also finds no violations, and that is
      # indistinguishable from a clean schema.
      #
      # MEASURED, not guessed: 22 tables and 355 columns as of 2026-10-23 (35
      # corvid tables less the 13 reference tables). The floors sit just under, so
      # losing a table or a dozen columns to a widened exemption fails here
      # rather than passing quietly. The first version used 20/150 against
      # 31/400 — loose enough to lose a third of the schema unnoticed — and the
      # second used 300, which was the pre-exclusion count and failed on a
      # clean schema. Raise these when tables are added.
      assert_operator tables_scanned, :>=, 22,
        "scanned only #{tables_scanned} tables — the scan is broken, not the schema clean"
      assert_operator columns_scanned, :>=, 345,
        "scanned only #{columns_scanned} columns — the scan is broken, not the schema clean"
    end

    # The exceptions file is a disclosure document with dates in it. If the
    # dates are never read it is a permanent allowlist wearing a deadline, and
    # on the day after the last date a public repo shows a missed promise
    # instead of a kept one.
    def test_exception_entries_are_honest
      raw = YAML.load_file(EXCEPTIONS_FILE, permitted_classes: [ Date ]) || []

      bad_class = raw.reject { |e| VALID_CLASSIFICATIONS.include?(e["classification"]) }
      assert_empty bad_class.map { |e| "#{e['table']}.#{e['column']}=#{e['classification']}" },
        "every exception needs a classification from #{VALID_CLASSIFICATIONS.join(', ')}"

      # A false positive is not a disclosed exception — it is a gap in this
      # guard's allowlist, and it belongs in ENUM_COLUMNS or
      # permitted_by_convention? where widening the net is reviewed as code.
      # Leaving them here inflates the count in the one document whose purpose
      # is credibility.
      assert_empty raw.select { |e| e["classification"] == "false_positive" },
        "false_positive entries belong in the guard's allowlist, not the disclosure file"

      # A patient_phi entry with neither a date nor a named blocker is a
      # permanent allowlist entry wearing a classification. Tokenization is the
      # usual remediation and it needs a vault, which does not exist yet — so
      # `blocked_on` is legitimate, but it has to NAME the blocker rather than
      # leave the entry open-ended.
      undated = raw.select do |e|
        e["classification"] == "patient_phi" &&
          e["remediate_by"].nil? && e["blocked_on"].to_s.strip.empty?
      end
      assert_empty undated.map { |e| "#{e['table']}.#{e['column']}" },
        "a patient_phi entry needs a remediate_by date or a named blocked_on"

      expired = raw.select do |e|
        next false if %w[needs_decision unclassified].include?(e["classification"])
        next false if e["classification"] == "accepted_workflow_date"
        next false if e["remediate_by"].nil?
        next false unless e["blocked_on"].to_s.strip.empty?

        Date.parse(e["remediate_by"].to_s) < Date.current
      end
      assert_empty expired.map { |e| "#{e['table']}.#{e['column']} due #{e['remediate_by']}" },
        "remediate_by has passed — either remediate the column or re-date the entry deliberately"
    end

    # bounded? is what lets an ENUM_COLUMNS name through, so it must mean
    # "a CHECK constraint confines THIS column to a value list". A substring
    # match also counted a column that a constraint merely mentions:
    # eligibility_group_set_at appears only in a both-or-neither pairing
    # check, and rule_key only in "rule_key IS NULL" — neither bounds what
    # the column can hold.
    def test_bounded_requires_a_value_list_on_the_column_itself
      assert bounded?("corvid_fmap_determinations", "category")
      assert bounded?("corvid_alternate_resource_checks", "eligibility_group")
      assert bounded?("corvid_api_call_logs", "api_name")

      refute bounded?("corvid_alternate_resource_checks", "eligibility_group_set_at"),
        "a pairing check that mentions the column does not bound its values"
      refute bounded?("corvid_fmap_determinations", "rule_key"),
        "an IS NULL clause does not bound the column's values"
      refute bounded?("corvid_alternate_resource_checks", "group"),
        "a constraint on eligibility_group must not bound a column named group"
    end

    # REFERENCE_TABLES skips a whole table, so it must hold only global
    # published data. A tenant_identifier means a host writes the rows — that
    # is configuration, and its columns need the per-column scan.
    def test_reference_tables_are_not_tenant_data
      tenant_tables = REFERENCE_TABLES.select do |table|
        ActiveRecord::Base.connection.columns(table).any? { |c| c.name == "tenant_identifier" }
      end
      assert_empty tenant_tables, "tenant-scoped tables are not reference data"
    end

    # The same rule on constraint text no schema here happens to contain: an
    # exclusion list leaves the column unbounded, whatever the cast.
    def test_an_exclusion_list_is_not_a_bound
      assert confines_to_value_list?("status::text = ANY (ARRAY['a'::character varying])", "status")
      assert confines_to_value_list?("status::character varying IN ('a')", "status")

      refute confines_to_value_list?("status::text NOT IN ('a')", "status")
      refute confines_to_value_list?("status::character varying NOT IN ('a')", "status")
      refute confines_to_value_list?("status::text <> ALL (ARRAY['a'::character varying])", "status")
    end

    # Owner decision on #591 (ADR 0002): a permit that rests on the column's
    # values being bounded needs the DATABASE to bound them. Model validation
    # alone is not enough — a direct insert, update_column or a later writer
    # skips it. rule_key and rule_citations are bounded only by the model
    # today, so they are not permitted until #704 adds the constraint.
    def test_a_value_bound_permit_needs_a_database_constraint
      refute permitted_by_convention?("rule_key", :string, "corvid_fmap_determinations"),
        "rule_key is validated by the model only, not by a database constraint"
      refute permitted_by_convention?("rule_citations", :jsonb, "corvid_fmap_determinations"),
        "rule_citations is validated by the model only, not by a database constraint"

      assert permitted_by_convention?("category", :string, "corvid_fmap_determinations"),
        "a CHECK-bounded enum is still permitted"
    end

    # A foreign key bounds a column to the keys of another table, which is
    # the bound #704 proposes for best_available_rule_key.
    def test_a_foreign_key_is_a_database_bound
      assert db_bounded?("corvid_case_programs", "case_id")
      refute db_bounded?("corvid_fmap_determinations", "best_available_rule_key")
    end

    # Owner decision on #591: an open entry (unclassified or needs_decision)
    # must say who owns it — an issue number or a deadline date. Otherwise it
    # is a permanent allowlist entry with no one accountable for it.
    def test_every_open_entry_is_tracked
      assert_empty untracked_open_entries(exception_entries).map { |e| "#{e['table']}.#{e['column']}" },
        "every unclassified or needs_decision entry needs an issue (\"#123\") or a remediate_by date"
    end

    def test_an_open_entry_needs_an_issue_or_a_deadline
      entries = [
        { "column" => "a", "classification" => "unclassified" },
        { "column" => "b", "classification" => "needs_decision", "issue" => "704" },
        { "column" => "c", "classification" => "unclassified", "issue" => "see #704 later" },
        { "column" => "d", "classification" => "unclassified", "remediate_by" => "soon" },
        { "column" => "e", "classification" => "unclassified", "blocked_on" => "the design" },
        { "column" => "f", "classification" => "unclassified", "issue" => "#704" },
        { "column" => "g", "classification" => "needs_decision", "remediate_by" => "2027-01-15" },
        { "column" => "h", "classification" => "accepted_workflow_date" }
      ]

      assert_equal %w[a b c d e], untracked_open_entries(entries).map { |e| e["column"] }
    end

    # A deadline on an open entry is read like any other: once it passes,
    # the entry fails, so a date cannot be used as a decoration.
    def test_a_dated_open_entry_expires
      entries = [
        { "column" => "a", "classification" => "needs_decision", "remediate_by" => "2000-01-01" },
        { "column" => "b", "classification" => "unclassified", "remediate_by" => "2000-01-01", "issue" => "#704" },
        { "column" => "c", "classification" => "unclassified", "issue" => "#704" }
      ]

      assert_equal %w[a b], expired_entries(entries).map { |e| e["column"] }
    end

    private

    def build_message(violations)
      hard = violations.select { |v| v[:hard] }
      soft = violations.reject { |v| v[:hard] }
      msg = +"Columns that can hold PHI and are not disclosed:\n\n"
      if hard.any?
        msg << "HARD FAILURES (never permitted, exceptions file cannot suppress these):\n"
        hard.each { |v| msg << "  #{v[:table]}.#{v[:column]} (#{v[:type]}) — #{v[:reason]}\n" }
        msg << "\n"
      end
      soft.group_by { |v| v[:table] }.sort.each do |table, cols|
        msg << "#{table}:\n"
        cols.sort_by { |c| c[:column] }.each do |c|
          msg << "  - #{c[:column]} (#{c[:type]}) — #{c[:reason]}\n"
        end
      end
      msg << "\nEither tokenize/drop the column, permit it by convention in this test "
      msg << "(reviewed as code), or disclose it in docs/phi-column-exceptions.yml with a "
      msg << "classification and a real date."
      msg
    end

    # Why this column would be an identifier under 45 CFR 164.514(b)(2) if it
    # held what its name suggests. Advisory: under default-deny a column is
    # flagged for its TYPE, and the category is there to help whoever triages.
    def hipaa_category(name, type)
      case
      when name.match?(/name/)              then "(A) Names"
      when name.match?(/dob|birth/)         then "(C) Dates directly related to an individual"
      when name.match?(/address|city|zip/)  then "(B) Geographic subdivisions"
      when name.match?(/phone|fax/)         then "(D) Telephone numbers"
      when name.match?(/email/)             then "(F) Email addresses"
      when name.match?(/ssn/)               then "(G) Social security numbers"
      when name.match?(/mrn|dfn/)           then "(H) Medical record numbers"
      when name.match?(/policy|member/)     then "(I) Health plan beneficiary numbers"
      when name.match?(/account|check_number|authorization_number/)
        "(R) Any other unique identifying number"
      when name.match?(/url|uri/)           then "(M) URLs"
      when type == :date || type == :datetime
        "(C) Dates directly related to an individual"
      when %i[text jsonb binary].include?(type)
        "free-form #{type} — can hold any of (A)-(R)"
      else
        "free-form #{type} — capacity unconstrained"
      end
    end

    def load_exceptions
      return Hash.new { |h, k| h[k] = [] } unless File.exist?(EXCEPTIONS_FILE)

      # permitted_classes: an UNQUOTED date in the yml makes Psych 4 raise
      # DisallowedClass, which errors load_exceptions and takes the FIRST test
      # red with a message about YAML classes rather than about PHI.
      data = YAML.load_file(EXCEPTIONS_FILE, permitted_classes: [ Date ]) || []
      data.each_with_object(Hash.new { |h, k| h[k] = [] }) do |entry, acc|
        acc[entry["table"]] << entry["column"]
      end
    end
  end
end
