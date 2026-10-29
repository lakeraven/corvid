# frozen_string_literal: true

module Corvid
  # Analyzes a parsed RPMS PRC report and computes Medicare-Like Rate
  # overpayment per obligation under 42 CFR 136.30. Routes each obligation
  # to the appropriate CMS payment system based on its mapped billing code:
  # PFS for professional services, IPPS DRG for inpatient hospital, OPPS
  # APC for hospital outpatient.
  #
  # Per-payment-system data status:
  #   - PFS uses real ingested CMS data → :clear results.
  #   - IPPS routes through real CMS Final Rule data when loaded for the
  #     (year, DRG, locality) — :clear / :real. When the loaded row's
  #     release_label starts with "stub" (seed canonical CSVs from the
  #     release), or no row is loaded and the in-code IppsStubRateProvider
  #     fills in, results are :stub_estimate / :stub. See
  #     docs/cms_ipps_data.md for coverage status by FY and the
  #     production-ingest workflow.
  #   - OPPS routes through real CMS Final Rule data when loaded for
  #     the (calendar year, APC, locality) — :clear / :real. When the
  #     loaded row's release_label starts with "stub", or no row is
  #     loaded and the in-code OppsStubRateProvider fills in, results
  #     are :stub_estimate / :stub. OPPS uses calendar-year boundaries
  #     (Jan 1), unlike IPPS which uses federal fiscal year.
  #
  # **Screening estimate, not adjudication.** The IPPS pricing formula
  # (`weight × base_rate × wage_index`) is the standard operating
  # payment, intentionally without IME, DSH, capital, outlier, or
  # transfer adjustments. The OPPS formula
  # (`apc_weight × conversion_factor × wage_index`) similarly omits
  # status-indicator packaging, copay/coinsurance, outlier, and
  # device/drug pass-through adjustments. Both are recovery-triage
  # screening estimates — not claim-adjudication amounts. Demand-letter
  # dollar figures should cite the analyzer's source/confidence labels
  # alongside any total.
  #
  # Public contract notes for callers:
  #   - Result#recovery_confidence values: :clear, :stub_estimate,
  #     :unmapped_procedure, :unmapped_facility, :no_rate_for_year
  #   - Result#rate_source values: :real (PFS / IPPS / OPPS with real
  #     CMS data) or :stub (IPPS / OPPS fallback when real data isn't
  #     loaded for the year)
  #   - Result#wage_area is the CMS wage area for an institutional
  #     result (IPPS, OPPS, ASC): the crosswalk code, or nil when the
  #     facility ZIP is missing or malformed or that fiscal year has
  #     no crosswalk row (priced as NATIONAL). Result#crosswalk_release
  #     is that row's release_label, or nil when the label is blank or
  #     there is no row. Professional PFS,
  #     unmapped, and missing-date results leave both nil. Institutional
  #     notes end with "Wage area: <code> (crosswalk release <label>)."
  #     when the row has a release label, or "Wage area: <code>." when
  #     that label is blank. A missing or malformed ZIP ends with
  #     "Wage area: NATIONAL (facility ZIP missing or malformed)." A
  #     well-formed ZIP with no row ends with "Wage area: NATIONAL
  #     (no crosswalk row for the facility ZIP in FY <year>)." The
  #     sentence stays last, after any CAH text. Notes do not include
  #     the facility ZIP. A resolved area with no wage-index row still
  #     prices on the NATIONAL wage index. A crosswalk release_label
  #     that starts with "stub" marks the institutional result :stub
  #     and :stub_estimate even when the rate rows are real CMS data.
  #     On the IPPS, OPPS, and ASC real paths that stub label is
  #     rate_source_release: if any input row is stub-derived, the
  #     stub label wins, the same rule the rate providers use. The
  #     pricing sentence keeps the real-rule wording and the rate
  #     row's release; the wage-area sentence names the crosswalk
  #     release.
  #   - Summary exposes total_overpayment_known (sum where confidence is
  #     :clear) and total_overpayment_stub_estimate (sum where confidence
  #     is :stub_estimate). total_medicare_equivalent intentionally
  #     sums only :clear results — the stub-derived equivalent dollars
  #     belong to a different statistical population and shouldn't mix
  #     into a single "Medicare-equivalent" figure on a report.
  module PrcOverpaymentAnalyzer
    # Per-obligation result. rate_source_release carries the
    # release_label of the underlying rate row (PFS FeeScheduleEntry,
    # IppsDrgWeight/IppsHospitalRate, OppsApcWeight/OppsConversionFactor)
    # so PrcImporter.reanalyze can persist provenance and the audit
    # packet's methodology.json can attribute each recoverable dollar
    # to a specific CMS release. On the IPPS, OPPS, and ASC real
    # paths, a crosswalk release_label that starts with "stub" wins
    # over that rate-row label. Nil for in-code stub fallback or
    # exception paths (no source release to attribute).
    # wage_area is the crosswalk code for institutional results, or
    # nil when the ZIP is missing, malformed, or that fiscal year has
    # no crosswalk row. Nil for professional, unmapped, and
    # missing-date results. It is not a PFS locality. It stays nil
    # for a NATIONAL price so the note can tell a missing ZIP from a
    # missing row; the persisted analysis column stores "NATIONAL"
    # for that institutional miss.
    # crosswalk_release is that row's release_label, or nil when the
    # label is blank or there is no row. Professional, unmapped, and
    # missing-date results leave it nil. Both values come from the
    # crosswalk row already loaded for the obligation.
    Result = Struct.new(
      :obligation_id, :patient_dfn, :vendor_id,
      :procedure_code, :hcpcs, :drg, :apc, :procedure_description,
      :service_date, :facility_zip, :locality,
      :billed_amount, :paid_amount,
      :medicare_equivalent, :overpayment,
      :payment_system, :rate_source, :recovery_confidence,
      :rate_source_release,
      :wage_area,
      :crosswalk_release,
      :notes,
      keyword_init: true
    )

    # Aggregate roll-up returned by `analyze`.
    Summary = Struct.new(
      :obligations_analyzed,
      :total_billed, :total_paid,
      :total_medicare_equivalent, :total_overpayment_known,
      :total_overpayment_stub_estimate,
      :by_confidence,
      :results,
      keyword_init: true
    )

    # Recovery confidence levels.
    #   :clear                  — Medicare equivalent from real CMS data; overpayment is final
    #   :stub_estimate          — Hospital obligation priced via stub provider; rough but actionable
    #   :unmapped_procedure     — Procedure description not in PrcProcedureDictionary
    #   :unmapped_facility      — RPMS facility code not in PrcFacilityDictionary
    #   :no_rate_for_year       — DB has no PFS row for this CPT/locality on the service date
    #   :missing_service_date   — Obligation has no parseable service_date (malformed
    #                             YYYYMMDD upstream); ops must clean the obligation itself,
    #                             distinct from a fee-schedule gap.

    class << self
      def analyze(report)
        results = report.obligations.map { |o| analyze_obligation(o, report.header) }
        summarize(results)
      end

      def analyze_obligation(obligation, header)
        # Short-circuit before procedure/facility lookup: without a
        # service_date, none of the downstream rate paths can do
        # anything sensible. Route this to its own ops-triage reason
        # rather than letting it fall through to :no_rate_for_year,
        # which would mislead ops into looking for missing rate data.
        return missing_service_date(obligation) if obligation.service_date.nil?

        proc_info = Corvid::PrcProcedureDictionary.lookup(obligation.procedure_code)
        facility = Corvid::PrcFacilityDictionary.lookup(header.facility)

        return unmapped_procedure(obligation, facility) unless proc_info
        return unmapped_facility(obligation, proc_info) unless facility

        # One crosswalk row for the whole institutional obligation.
        # Professional pricing does not query the crosswalk.
        crosswalk = institutional_wage_crosswalk(proc_info, facility, obligation)
        result = if proc_info.drg
          analyze_inpatient(obligation, proc_info, facility, crosswalk)
        elsif proc_info.apc
          analyze_outpatient(obligation, proc_info, facility, crosswalk)
        else
          analyze_professional(obligation, proc_info, facility)
        end

        # CAH edits the note first so the wage-area sentence stays last.
        append_wage_area_note(apply_cah_adjustment(result), crosswalk)
      end

      private

      # Critical Access Hospitals are paid by Medicare at 101% of reasonable
      # cost. Apply the same 1.01× ceiling at the analyzer boundary when the
      # obligation's vendor is on the CAH registry and the CAH designation
      # was in effect on the service date. The underlying rate row's
      # release_label is preserved so audit-packet provenance is unchanged.
      # Called from analyze_obligation so both the batch path
      # (PrcOverpaymentAnalyzer.analyze) and the per-row importer path
      # (PrcImporter.reanalyze → analyze_obligation) get the adjustment.
      def apply_cah_adjustment(result)
        return result if result.medicare_equivalent.nil?
        return result unless Corvid::CahFacility.applies?(
          vendor_id: result.vendor_id, on: result.service_date
        )

        adjusted = (BigDecimal(result.medicare_equivalent.to_s) * BigDecimal("1.01")).round(2).to_f
        paid = result.paid_amount.to_f
        result.medicare_equivalent = adjusted
        result.overpayment = [ paid - adjusted, 0 ].max.round(2)
        existing = result.notes.to_s
        suffix = " [CAH 1.01× multiplier applied]"
        result.notes = existing.empty? ? suffix.strip : "#{existing}#{suffix}"
        result
      end

      def analyze_professional(obligation, proc_info, facility)
        entry = professional_entry(proc_info.hcpcs, facility.locality, obligation.service_date)

        if entry.nil?
          return Result.new(
            base_fields(obligation, proc_info, facility).merge(
              payment_system: :pfs,
              rate_source: nil, # no rate looked up successfully
              recovery_confidence: :no_rate_for_year,
              notes: "No PFS rate found for CPT #{proc_info.hcpcs} in locality " \
                     "#{facility.locality} on #{obligation.service_date}"
            )
          )
        end

        rate = entry.medicare_rate.to_f.round(2)
        Result.new(
          base_fields(obligation, proc_info, facility).merge(
            medicare_equivalent: rate,
            overpayment: [ obligation.paid_amount.to_f - rate, 0 ].max.round(2),
            payment_system: :pfs,
            rate_source: :real,
            recovery_confidence: :clear,
            # .presence collapses "" → nil so a blank label doesn't leak
            # into methodology.json's rate_source_releases list.
            rate_source_release: entry.release_label.presence
          )
        )
      end

      def analyze_inpatient(obligation, proc_info, facility, crosswalk)
        # Resolved once per obligation, then reused for the IPPS lookup
        # and the stub fallback.
        area = wage_area(crosswalk)

        # IPPS lookup (#276): real CMS data first; fall back to in-code
        # stub provider when no row is loaded. Recovery confidence keys
        # off the loaded row's release_label — "stub_v1" (or any "stub_*"
        # prefix) marks :stub_estimate so seed canonical CSVs we ship
        # in the release don't get misrepresented as recoverable-now.
        # Real CMS Final Rule labels (e.g., "cms_fy2026_final_rule")
        # mark :clear / :real. A crosswalk release_label with that same
        # "stub" prefix downgrades the result even when this lookup is
        # real CMS data.
        lookup = Corvid::IppsRateProvider.lookup_for(
          drg_code: proc_info.drg,
          locality: area,
          date: obligation.service_date
        )

        if lookup
          # A stub-labelled crosswalk downgrades a real rate row the
          # same way a stub-labelled rate row does. The pricing note
          # still names the rate row's release. rate_source_release
          # is the crosswalk label when that label starts with "stub".
          provider_stub = stub_release?(lookup.release_label)
          stub_derived = provider_stub || stub_release?(crosswalk&.release_label)
          Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: lookup.rate,
              overpayment: [ obligation.paid_amount.to_f - lookup.rate, 0 ].max.round(2),
              payment_system: :ipps,
              rate_source: stub_derived ? :stub : :real,
              recovery_confidence: stub_derived ? :stub_estimate : :clear,
              rate_source_release: institutional_rate_source_release(lookup.release_label, crosswalk),
              wage_area: area,
              notes: provider_stub ?
                "Inpatient hospital claim (DRG #{proc_info.drg}). Priced via " \
                "stub-derived IPPS canonical CSV (release=#{lookup.release_label}); " \
                "replace with real CMS Final Rule data as it's normalized." :
                "Inpatient hospital claim (DRG #{proc_info.drg}). " \
                "Priced via real CMS IPPS Final Rule (release=#{lookup.release_label})."
            )
          )
        else
          stub_rate = Corvid::IppsStubRateProvider.rate_for(
            drg_code: proc_info.drg,
            locality: area,
            date: obligation.service_date
          )
          Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: stub_rate,
              overpayment: stub_rate ? [ obligation.paid_amount.to_f - stub_rate, 0 ].max.round(2) : nil,
              payment_system: :ipps,
              rate_source: stub_rate ? :stub : nil,
              recovery_confidence: stub_rate ? :stub_estimate : :no_rate_for_year,
              wage_area: area,
              notes: "Inpatient hospital claim (DRG #{proc_info.drg}). Real IPPS " \
                     "rate unavailable for this (year, DRG, locality); using stub " \
                     "national-average estimate."
            )
          )
        end
      end

      # Look up the Medicare professional-component rate for a CPT code,
      # locality, and service date directly via FeeScheduleEntry. Bypasses
      # a ZIP-to-locality step because the PRC dictionary
      # already gives us the locality.
      def professional_entry(cpt_code, locality, service_date)
        return nil if cpt_code.nil? || locality.nil? || service_date.nil?

        Corvid::FeeScheduleEntry.rate_for(
          cpt_code: cpt_code,
          locality: locality,
          date: service_date
        )
      end

      def analyze_outpatient(obligation, proc_info, facility, crosswalk)
        # Resolved once per obligation, then reused for ASC, OPPS, and
        # the OPPS stub.
        area = wage_area(crosswalk)

        # OPPS lookup (#277): real CMS data first; fall back to in-code
        # stub provider when no row is loaded. Mirrors the IPPS analyze_
        # inpatient pattern — the rate row's release_label drives the
        # pricing note, and a "stub" prefix on that label or on the
        # crosswalk release downgrades confidence. On these real paths
        # a stub-prefixed crosswalk label is rate_source_release.
        #
        # ASC routing (#278): when the obligation's vendor is in the
        # corvid_asc_facilities registry on the service date, route to
        # AscRateProvider. ASC publishes rates per HCPCS (not per APC),
        # so we pass proc_info.hcpcs — different lookup key than OPPS.
        # If the ASC lookup misses (procedure isn't ASC-covered, or
        # our Addendum AA data isn't loaded for that year), fall
        # through to the OPPS path as a conservative default rather
        # than dropping straight to the stub provider.
        is_asc = Corvid::AscFacility.applies?(
          vendor_id: obligation.vendor_id, on: obligation.service_date
        )
        asc_lookup = is_asc ? Corvid::AscRateProvider.lookup_for(
          hcpcs_code: proc_info.hcpcs,
          locality: area,
          date: obligation.service_date
        ) : nil

        if asc_lookup
          provider_stub = stub_release?(asc_lookup.release_label)
          stub_derived = provider_stub || stub_release?(crosswalk&.release_label)
          return Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: asc_lookup.rate,
              overpayment: [ obligation.paid_amount.to_f - asc_lookup.rate, 0 ].max.round(2),
              payment_system: :asc,
              rate_source: stub_derived ? :stub : :real,
              recovery_confidence: stub_derived ? :stub_estimate : :clear,
              rate_source_release: institutional_rate_source_release(asc_lookup.release_label, crosswalk),
              wage_area: area,
              notes: provider_stub ?
                "Ambulatory surgical center (HCPCS #{proc_info.hcpcs}). Priced via " \
                "stub-derived ASC canonical CSV (release=#{asc_lookup.release_label})." :
                "Ambulatory surgical center (HCPCS #{proc_info.hcpcs}). " \
                "Priced via real CMS ASC Final Rule (release=#{asc_lookup.release_label})."
            )
          )
        end

        lookup = Corvid::OppsRateProvider.lookup_for(
          apc_code: proc_info.apc,
          locality: area,
          date: obligation.service_date
        )

        if lookup
          provider_stub = stub_release?(lookup.release_label)
          stub_derived = provider_stub || stub_release?(crosswalk&.release_label)
          Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: lookup.rate,
              overpayment: [ obligation.paid_amount.to_f - lookup.rate, 0 ].max.round(2),
              payment_system: :opps,
              rate_source: stub_derived ? :stub : :real,
              recovery_confidence: stub_derived ? :stub_estimate : :clear,
              rate_source_release: institutional_rate_source_release(lookup.release_label, crosswalk),
              wage_area: area,
              notes: provider_stub ?
                "Hospital outpatient (APC #{proc_info.apc}). Priced via " \
                "stub-derived OPPS canonical CSV (release=#{lookup.release_label})." :
                "Hospital outpatient (APC #{proc_info.apc}). " \
                "Priced via real CMS OPPS Final Rule (release=#{lookup.release_label})."
            )
          )
        else
          stub_rate = Corvid::OppsStubRateProvider.rate_for(
            apc_code: proc_info.apc,
            locality: area,
            date: obligation.service_date
          )
          Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: stub_rate,
              overpayment: stub_rate ? [ obligation.paid_amount.to_f - stub_rate, 0 ].max.round(2) : nil,
              payment_system: :opps,
              rate_source: stub_rate ? :stub : nil,
              recovery_confidence: stub_rate ? :stub_estimate : :no_rate_for_year,
              wage_area: area,
              notes: "Hospital outpatient (APC #{proc_info.apc}). Real OPPS " \
                     "rate unavailable for this (year, APC, locality); using " \
                     "stub national-average estimate."
            )
          )
        end
      end

      def unmapped_procedure(obligation, facility)
        Result.new(
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          service_date: obligation.service_date,
          facility_zip: facility&.zip,
          locality: facility&.locality,
          billed_amount: obligation.billed_amount.to_f,
          paid_amount: obligation.paid_amount.to_f,
          recovery_confidence: :unmapped_procedure,
          notes: "Procedure code '#{obligation.procedure_code}' not in PrcProcedureDictionary. " \
                 "Register a mapping to enable repricing."
        )
      end

      def unmapped_facility(obligation, proc_info)
        Result.new(
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          hcpcs: proc_info.hcpcs,
          procedure_description: proc_info.description,
          service_date: obligation.service_date,
          billed_amount: obligation.billed_amount.to_f,
          paid_amount: obligation.paid_amount.to_f,
          recovery_confidence: :unmapped_facility,
          notes: "Facility code not in PrcFacilityDictionary; cannot determine locality."
        )
      end

      def missing_service_date(obligation)
        Result.new(
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          service_date: nil,
          billed_amount: obligation.billed_amount.to_f,
          paid_amount: obligation.paid_amount.to_f,
          recovery_confidence: :missing_service_date,
          notes: "Obligation has no parseable service_date (upstream date malformed); " \
                 "cannot select a fee schedule. Clean the obligation row, then re-import."
        )
      end

      # One ZipCbsaCrosswalk read per institutional obligation.
      # Professional obligations do not query the crosswalk. Nil is a
      # missing or malformed ZIP, or no row for that fiscal year.
      def institutional_wage_crosswalk(proc_info, facility, obligation)
        return unless proc_info.drg || proc_info.apc

        Corvid::PrcFacilityDictionary.crosswalk_for(
          zip: facility.zip, on: obligation.service_date
        )
      end

      # CMS wage area for one institutional obligation: the 5-digit
      # CBSA or 2-digit rural-state code on the crosswalk row resolved
      # once for the service date. analyze_obligation loads that row
      # before any rate lookup, and analyze_inpatient /
      # analyze_outpatient pass this code into every IPPS, OPPS, ASC,
      # and stub lookup on the obligation.
      #
      # PFS locality codes are a separate numbering system and overlap
      # these wage areas (PFS "02" is Seattle; wage area "02" is rural
      # Alaska), so this returns the crosswalk row's cbsa and never
      # facility.locality. crosswalk_for returns nil for a non-String
      # ZIP, a malformed ZIP, a missing ZIP, or a fiscal year with no
      # crosswalk row. Nil is passed through; the rate providers treat
      # a nil locality as NATIONAL. A resolved code with no wage-index
      # row still prices on the NATIONAL wage index inside those
      # providers. Result#wage_area keeps the resolved code, or nil
      # for that miss.
      #
      # Institutional notes stay last, after any CAH suffix, and never
      # include the facility ZIP. A row with a release label ends with
      # "Wage area: <code> (crosswalk release <label>)." A blank label
      # ends with "Wage area: <code>." A nil, non-String, or malformed
      # ZIP ends with "Wage area: NATIONAL (facility ZIP missing or
      # malformed)." A well-formed ZIP with no row ends with
      # "Wage area: NATIONAL (no crosswalk row for the facility ZIP in
      # FY <year>)." Those two sentences use
      # PrcFacilityDictionary.normalized_zip and fiscal_year_for.
      # A crosswalk release_label that starts with "stub" marks the
      # institutional result rate_source :stub and recovery_confidence
      # :stub_estimate even when the rate rows are real CMS data.
      # On the real paths that label is rate_source_release. The
      # pricing sentence still names the rate row's release.
      def wage_area(crosswalk)
        crosswalk&.cbsa
      end

      def stub_release?(label)
        label.to_s.start_with?("stub")
      end

      # IPPS, OPPS, and ASC real paths. Same rule as the rate
      # providers: if any input row is stub-derived, the stub label
      # wins. A crosswalk release_label that starts with "stub" is
      # that label, even when the rate row's label is a real CMS
      # release. Otherwise the rate row's label stands. Blank labels
      # collapse to nil. The in-code fallback does not call this and
      # leaves rate_source_release nil.
      def institutional_rate_source_release(provider_label, crosswalk)
        crosswalk_label = crosswalk&.release_label
        if stub_release?(crosswalk_label)
          crosswalk_label.presence
        else
          provider_label.presence
        end
      end

      # Institutional notes end with the wage-area sentence. Called
      # after the CAH suffix so that sentence stays last. Professional
      # notes are left alone. The sentence never includes the facility
      # ZIP; normalized_zip is only the well-formed check.
      def append_wage_area_note(result, crosswalk)
        return result unless %i[ipps opps asc].include?(result.payment_system)

        # Same row analyze_obligation already loaded. Blank labels
        # collapse to nil so methodology.json does not list "".
        result.crosswalk_release = crosswalk&.release_label.presence
        sentence = wage_area_note(result, crosswalk)
        existing = result.notes.to_s
        result.notes = existing.empty? ? sentence : "#{existing} #{sentence}"
        result
      end

      def wage_area_note(result, crosswalk)
        area = result.wage_area
        return national_wage_area_note(result) if area.nil?

        label = crosswalk&.release_label.presence
        if label
          "Wage area: #{area} (crosswalk release #{label})."
        else
          "Wage area: #{area}."
        end
      end

      def national_wage_area_note(result)
        if Corvid::PrcFacilityDictionary.normalized_zip(result.facility_zip).nil?
          "Wage area: NATIONAL (facility ZIP missing or malformed)."
        else
          year = Corvid::PrcFacilityDictionary.fiscal_year_for(result.service_date)
          "Wage area: NATIONAL (no crosswalk row for the facility ZIP in FY #{year})."
        end
      end

      def base_fields(obligation, proc_info, facility)
        {
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          hcpcs: proc_info.hcpcs,
          drg: proc_info.drg,
          apc: proc_info.apc,
          procedure_description: proc_info.description,
          service_date: obligation.service_date,
          facility_zip: facility.zip,
          locality: facility.locality,
          billed_amount: obligation.billed_amount.to_f,
          paid_amount: obligation.paid_amount.to_f
        }
      end

      def summarize(results)
        by_confidence = results.group_by(&:recovery_confidence).transform_values(&:size)
        clear = results.select { |r| r.recovery_confidence == :clear }
        stub = results.select { |r| r.recovery_confidence == :stub_estimate }

        Summary.new(
          obligations_analyzed: results.size,
          total_billed: sum(results, :billed_amount),
          total_paid: sum(results, :paid_amount),
          total_medicare_equivalent: sum(clear, :medicare_equivalent),
          total_overpayment_known: sum(clear, :overpayment),
          total_overpayment_stub_estimate: sum(stub, :overpayment),
          by_confidence: by_confidence,
          results: results
        )
      end

      def sum(results, attr)
        results.sum { |r| r.send(attr).to_f }.round(2)
      end
    end
  end
end
