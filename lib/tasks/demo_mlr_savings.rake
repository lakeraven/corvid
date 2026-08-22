# frozen_string_literal: true

# GM-6 · MLR repricing savings demo — the headline number (corvid#469).
#
# Builds a representative annual purchased/referred-care (PRC) claim
# panel for a 2-provider Urban Indian Organization (UIO) street-
# medicine clinic in Billings, MT, feeds it through the *real*
# Corvid::PrcReportParser -> Corvid::PrcOverpaymentAnalyzer pipeline
# (the same code path production PRC imports run through), and prints
# the one headline number: total annual dollars saved by repricing
# every purchased-care claim to its Medicare-Like Rate (MLR) under
# 42 CFR 136.30, instead of paying the vendor's billed charge.
#
# Real vs. representative, plainly:
#   - The MLR side (PFS/IPPS/OPPS rates) is 100% real CMS CY2026/FY2026
#     data, hand-verified against the raw CMS source files (see
#     REAL CMS DATA section below for citations). This is the same
#     "rate_source: :real, recovery_confidence: :clear" path
#     production PRC imports get today.
#   - The claim panel (patient count, referral rate, code mix, and
#     billed-charge-to-Medicare multipliers) is representative/
#     synthetic — no PHI, ground rules documented inline and in
#     docs/gm6_mlr_savings_methodology.md.
#
# Reproduce: bundle exec rails demo:mlr_savings
namespace :demo do
  desc "GM-6: build a representative 2-provider UIO PRC claim panel and reprice it to MLR (corvid#469)"
  task mlr_savings: :environment do
    Corvid::Gm6::MlrSavingsDemo.run
  end
end

module Corvid
  module Gm6
    # See file header above for the real-vs-representative split.
    module MlrSavingsDemo
      FACILITY_CODE = "GM6"

      # ---------------------------------------------------------------
      # REAL CMS DATA
      #
      # Hand-verified against the raw CMS source files fetched via the
      # existing production pipeline (`rake cms:fetch[2026]`,
      # `rake cms:ipps:fetch_release[2026]`, `rake cms:opps:fetch_release[2026]`)
      # rather than re-run live at demo time, for two reasons:
      #
      #   1. Determinism/reliability for a live Aug 28 demo — no network
      #      dependency on GitHub Releases during the pitch.
      #   2. `Corvid::CmsFeeScheduleParser` has two real bugs on the
      #      CY2026+ PPRRVU layout, found while building this task
      #      (filed as a follow-up issue — see PR description):
      #        a. `parse_gpcis` keys solely on the 2-digit locality
      #           code, which collides across MACs/states that reuse
      #           the same number (Montana's locality "01" is not the
      #           only "01" nationally) — last file row wins.
      #        b. The `mp_col` header-detection fallback
      #           (`work_col + 9`) mis-targets the CY2026 file's dual
      #           NON-FAC/FACILITY PE RVU column layout, landing on the
      #           GLOB DAYS column instead of MP RVU (confirmed: DB rows
      #           imported via `rake cms:import[2026]` show mp_rvu: 0.0
      #           for CPT 99213, vs. the correct 0.09 read directly off
      #           the CMS file).
      #      Real IPPS/OPPS data (no known bugs) WAS pulled live via
      #      the production tasks and independently cross-checked
      #      against public CMS Final Rule summaries before being
      #      copied here as literals.
      #
      # PFS: CY2026 Medicare Physician Fee Schedule, Montana locality 01
      #   (MAC 03202, "MONTANA", statewide — CMS Addendum E,
      #   GPCI2026.csv / 26LOCCO.csv from RVU26A.zip).
      #   Work GPCI (with 1.0 floor) 1.000, PE GPCI 1.000, MP GPCI 0.998.
      #   Conversion factor (non-QP, CY2026 PFS Final Rule CMS-1832-F):
      #   $33.4009 — read directly off each row of PPRRVU2026_Jan_nonQPP.csv
      #   (also independently confirmed via CMS CY2026 PFS fact sheet;
      #   NOTE this differs from the stale $32.74 hardcoded in
      #   Corvid::CmsFeeScheduleParser::CONVERSION_FACTORS[2026], part
      #   of the same follow-up issue).
      #   RVU components read directly off PPRRVU2026_Jan_nonQPP.csv
      #   (HCPCS, work RVU, non-facility PE RVU, MP RVU):
      MONTANA_LOCALITY = "01"
      PFS_EFFECTIVE_DATE = Date.new(2026, 1, 1)
      PFS_CONVERSION_FACTOR = 33.4009
      PFS_GPCI = { work: 1.000, pe: 1.000, mp: 0.998 }.freeze
      PFS_RELEASE_LABEL = "cms_pfs_cy2026_final_rule_mt01_handverified"

      # code => [description, work_rvu, non-facility pe_rvu, mp_rvu]
      PFS_CODES = {
        "99213" => [ "Office/outpatient visit, established patient, low complexity", 1.30, 1.46, 0.09 ],
        "99214" => [ "Office/outpatient visit, established patient, moderate complexity", 1.92, 2.00, 0.14 ],
        "99203" => [ "Office/outpatient visit, new patient, low complexity", 1.60, 1.76, 0.16 ],
        "12001" => [ "Simple repair of superficial wound(s), ≤ 2.5 cm", 0.82, 2.41, 0.18 ],
        "93000" => [ "Electrocardiogram, complete", 0.17, 0.27, 0.02 ]
      }.freeze

      #   IPPS: FY2026 Final Rule (CMS-1833-F), national base rate and
      #   DRG relative weights — read directly off
      #   ipps_hospital_rates_FY2026.csv / ipps_drg_weights_FY2026.csv
      #   from the cms-fee-schedules-v1 release (via
      #   `rake cms:ipps:fetch_release[2026]`). Base rate $6,752.61
      #   independently confirmed against CMS's published FY2026 IPPS
      #   final-rule payment brief. Wage index 1.0 (NATIONAL row) —
      #   Billings, MT (CBSA 13740) real per-CBSA wage index (0.8961,
      #   per PR #467) is not applied here: production doesn't yet
      #   resolve a facility ZIP to a CBSA row (#372, tracked
      #   separately), so this demo matches current production
      #   behavior rather than hand-wiring a shortcut. Because
      #   Billings' real wage index (0.8961) is BELOW 1.0, the true
      #   Billings-adjusted MLR would be LOWER and the savings number
      #   HIGHER — this demo is conservative, not inflated.
      IPPS_FISCAL_YEAR = 2026
      IPPS_BASE_RATE = 6752.61
      IPPS_WAGE_INDEX = 1.0
      IPPS_RELEASE_LABEL = "cms_fy2026_final_rule"

      # drg_code => [description, relative_weight]
      IPPS_CODES = {
        "872" => [ "Septicemia or severe sepsis w/o MV 96+ hours w/o MCC", 1.0233 ],
        "603" => [ "Cellulitis w/o MCC", 0.8709 ]
      }.freeze

      #   OPPS: CY2026 Final Rule (CMS-1834-FC), national conversion
      #   factor and APC relative weights — read directly off
      #   opps_apc_weights_CY2026.csv / opps_conversion_factors_CY2026.csv
      #   from the cms-fee-schedules-v1 release (via
      #   `rake cms:opps:fetch_release[2026]`). CF $91.4150
      #   independently confirmed against CMS's CY2026 OPPS fact
      #   sheet. Wage index 1.0 (NATIONAL row) for the same reason as
      #   IPPS above — conservative, not inflated.
      OPPS_CALENDAR_YEAR = 2026
      OPPS_CONVERSION_FACTOR = 91.4150
      OPPS_WAGE_INDEX = 1.0
      OPPS_RELEASE_LABEL = "cms_opps_cy2026_final_rule"

      # apc_code => [description, corresponding ED-visit HCPCS (informational only), relative_weight]
      OPPS_CODES = {
        "5023" => [ "Hospital outpatient ED visit, level 3 (moderate)", "99283", 3.0508 ],
        "5024" => [ "Hospital outpatient ED visit, level 4 (high)", "99284", 4.6634 ],
        "5025" => [ "Hospital outpatient ED visit, level 5 (highest)", "99285", 6.6557 ]
      }.freeze

      # ---------------------------------------------------------------
      # REPRESENTATIVE CLAIM PANEL (synthetic, no PHI)
      #
      # Panel-size assumption: a 2-provider UIO street-medicine clinic
      # empanels roughly 500-700 active patients per provider (below
      # the ~1,500-2,500 standard primary-care panel, reflecting
      # higher case complexity in a street-medicine population) —
      # 1,200 active patients total.
      #
      # Referral-rate assumption: ~20% of the panel has at least one
      # purchased/referred-care episode in a year (professional
      # referral, ED visit, or hospitalization) — higher than a
      # general-population primary-care panel because of elevated
      # specialty/ED/hospital need in this population — ~240 patients,
      # generating ~300 total obligations (some patients have more
      # than one claim).
      #
      # Annual spend sanity check: this panel (see code mix below)
      # totals ~$126K in billed purchased-care charges across 300
      # claims for a 1,200-patient panel — about $105/panel-patient/
      # year (~$525/referred-patient/year). That's a modest number on
      # purpose: small UIO PRC programs are chronically underfunded
      # and typically can only authorize a fraction of clinically
      # indicated referrals (frequently just Priority I / emergent
      # cases), so a constrained referral budget is the *realistic*
      # baseline, not an artifact of under-modeling. That's also the
      # sharper story for the demo: even on a modest, cash-strapped
      # referral budget, MLR repricing recovers real money the
      # program can put back into authorizing more care. Scale every
      # count in the mix tables below uniformly to size this to a
      # specific program's real referral volume.
      #
      # Code-mix assumption: 90% professional (E&M-weighted toward
      # low/moderate visits, plus minor procedures), ~9% hospital
      # outpatient ED visits, <1% (2 claims) inpatient hospitalization
      # — inpatient stays are rare, catastrophic-cost events for a
      # panel this size; this panel intentionally includes only two
      # to keep every dollar traceable to a named example claim,
      # matching corvid#469's ask for "1-2 inpatient stays."
      #
      # Billed-charge assumption: this demo does not have access to a
      # real vendor invoice for these codes, so provider billed
      # charges are modeled as a multiple of the real MLR-equivalent
      # rate above, using round multipliers loosely consistent with
      # published charge-to-Medicare benchmarks (professional charges
      # typically run ~150-250% of Medicare; hospital facility charges
      # run substantially higher). This is the one deliberately
      # representative input in the model — everything downstream of
      # it (the MLR side, and therefore the savings) is real CMS data
      # run through the real analyzer.
      BILLED_MULTIPLIER = { pfs: 1.8, opps: 3.0, ipps: 3.5 }.freeze

      # [pfs_hcpcs, count] — sums to 270 professional claims.
      PFS_MIX = [
        [ "99213", 110 ],
        [ "99214", 70 ],
        [ "99203", 40 ],
        [ "12001", 30 ],
        [ "93000", 20 ]
      ].freeze

      # [opps_apc, count] — sums to 28 outpatient ED claims.
      OPPS_MIX = [
        [ "5023", 16 ],
        [ "5024", 9 ],
        [ "5025", 3 ]
      ].freeze

      # [ipps_drg, count] — 2 inpatient stays (see code-mix note above).
      IPPS_MIX = [
        [ "872", 1 ],
        [ "603", 1 ]
      ].freeze

      class << self
        def run
          banner("GM-6 · MLR repricing savings demo (corvid#469)")
          seed_real_cms_rates!
          register_dictionaries!

          report = Corvid::PrcReportParser.parse(build_prc_export)
          summary = Corvid::PrcOverpaymentAnalyzer.analyze(report)

          print_headline(summary)
          print_example_claims(summary)
          print_breakdown(summary)
          summary
        end

        private

        def banner(title)
          puts
          puts "=" * 78
          puts title
          puts "=" * 78
        end

        # -- Seed real CMS rate data (see citations above) --------------

        def seed_real_cms_rates!
          PFS_CODES.each do |cpt, (_desc, work, pe, mp)|
            Corvid::FeeScheduleEntry
              .where(cpt_code: cpt, locality: MONTANA_LOCALITY, effective_date: PFS_EFFECTIVE_DATE)
              .delete_all
            Corvid::FeeScheduleEntry.create!(
              cpt_code: cpt, locality: MONTANA_LOCALITY, effective_date: PFS_EFFECTIVE_DATE,
              work_rvu: work, pe_rvu: pe, mp_rvu: mp,
              work_gpci: PFS_GPCI[:work], pe_gpci: PFS_GPCI[:pe], mp_gpci: PFS_GPCI[:mp],
              conversion_factor: PFS_CONVERSION_FACTOR, release_label: PFS_RELEASE_LABEL
            )
          end

          IPPS_CODES.each do |drg, (_desc, weight)|
            Corvid::IppsDrgWeight.where(fiscal_year: IPPS_FISCAL_YEAR, drg_code: drg).delete_all
            Corvid::IppsDrgWeight.create!(
              fiscal_year: IPPS_FISCAL_YEAR, drg_code: drg,
              relative_weight: weight, release_label: IPPS_RELEASE_LABEL
            )
          end
          Corvid::IppsHospitalRate.where(
            fiscal_year: IPPS_FISCAL_YEAR, locality: Corvid::IppsHospitalRate::NATIONAL_LOCALITY
          ).delete_all
          Corvid::IppsHospitalRate.create!(
            fiscal_year: IPPS_FISCAL_YEAR, locality: Corvid::IppsHospitalRate::NATIONAL_LOCALITY,
            base_rate: IPPS_BASE_RATE, wage_index: IPPS_WAGE_INDEX, release_label: IPPS_RELEASE_LABEL
          )

          OPPS_CODES.each do |apc, (_desc, _hcpcs, weight)|
            Corvid::OppsApcWeight.where(calendar_year: OPPS_CALENDAR_YEAR, apc_code: apc).delete_all
            Corvid::OppsApcWeight.create!(
              calendar_year: OPPS_CALENDAR_YEAR, apc_code: apc,
              relative_weight: weight, release_label: OPPS_RELEASE_LABEL
            )
          end
          Corvid::OppsConversionFactor.where(
            calendar_year: OPPS_CALENDAR_YEAR, locality: Corvid::OppsConversionFactor::NATIONAL_LOCALITY
          ).delete_all
          Corvid::OppsConversionFactor.create!(
            calendar_year: OPPS_CALENDAR_YEAR, locality: Corvid::OppsConversionFactor::NATIONAL_LOCALITY,
            conversion_factor: OPPS_CONVERSION_FACTOR, wage_index: OPPS_WAGE_INDEX,
            release_label: OPPS_RELEASE_LABEL
          )
        end

        def register_dictionaries!
          Corvid::PrcFacilityDictionary.register(
            FACILITY_CODE, name: "Example UIO Street-Medicine Clinic (demo)", city: "Billings", state: "MT",
            zip: "59101", locality: MONTANA_LOCALITY
          )

          PFS_CODES.each_key do |cpt|
            Corvid::PrcProcedureDictionary.register(
              "GM6_PFS_#{cpt}", hcpcs: cpt, description: PFS_CODES[cpt][0]
            )
          end
          OPPS_CODES.each_key do |apc|
            Corvid::PrcProcedureDictionary.register(
              "GM6_OPPS_#{apc}", hcpcs: OPPS_CODES[apc][1], apc: apc, description: OPPS_CODES[apc][0]
            )
          end
          IPPS_CODES.each_key do |drg|
            Corvid::PrcProcedureDictionary.register(
              "GM6_IPPS_#{drg}", drg: drg, description: IPPS_CODES[drg][0]
            )
          end
        end

        # -- Real-rate lookups used only to size the synthetic billed
        #    charge (see BILLED_MULTIPLIER note above). The analyzer
        #    re-derives these same rates independently at analyze time
        #    from the same seeded rows — this does not hand-compute the
        #    savings total, it only parameterizes the claim panel's
        #    billed-charge inputs. ---------------------------------------

        def pfs_mlr(cpt)
          Corvid::FeeScheduleEntry.rate_for(cpt_code: cpt, locality: MONTANA_LOCALITY, date: PFS_EFFECTIVE_DATE)
                                   .medicare_rate.round(2)
        end

        def opps_mlr(apc)
          Corvid::OppsRateProvider.rate_for(apc_code: apc, locality: MONTANA_LOCALITY, date: Date.new(OPPS_CALENDAR_YEAR, 6, 1))
        end

        def ipps_mlr(drg)
          Corvid::IppsRateProvider.rate_for(drg_code: drg, locality: MONTANA_LOCALITY, date: Date.new(IPPS_FISCAL_YEAR, 3, 1))
        end

        # -- Build the synthetic PRC export -----------------------------

        def build_prc_export
          lines = [ "H^PRC_EXPORT^#{FACILITY_CODE}^20261231^1" ]
          obligation_index = 0
          total_paid = 0.0

          vendor_pool = (1..15).map { |n| "VEND-%03d" % n }
          patient_pool = (1..240).map { |n| "DFN-%04d" % n }

          each_claim(PFS_MIX, :pfs) do |cpt, _seq|
            obligation_index += 1
            billed = (pfs_mlr(cpt) * BILLED_MULTIPLIER[:pfs]).round(2)
            date = spread_date(2026, 1, 1, 2026, 12, 15, obligation_index)
            lines << obligation_line(
              obligation_index, patient_pool, vendor_pool, "GM6_PFS_#{cpt}", date, billed
            )
            total_paid += billed
          end

          each_claim(OPPS_MIX, :opps) do |apc, _seq|
            obligation_index += 1
            billed = (opps_mlr(apc) * BILLED_MULTIPLIER[:opps]).round(2)
            date = spread_date(2026, 1, 1, 2026, 12, 15, obligation_index)
            lines << obligation_line(
              obligation_index, patient_pool, vendor_pool, "GM6_OPPS_#{apc}", date, billed
            )
            total_paid += billed
          end

          each_claim(IPPS_MIX, :ipps) do |drg, _seq|
            obligation_index += 1
            billed = (ipps_mlr(drg) * BILLED_MULTIPLIER[:ipps]).round(2)
            # Keep inpatient service dates inside Jan-Sep so
            # IppsRateProvider's federal-fiscal-year conversion stays
            # in FY2026 (Oct-Dec would roll to FY2027, unseeded here).
            date = spread_date(2026, 2, 1, 2026, 9, 15, obligation_index)
            lines << obligation_line(
              obligation_index, patient_pool, vendor_pool, "GM6_IPPS_#{drg}", date, billed
            )
            total_paid += billed
          end

          lines << "T^#{obligation_index}^#{patient_pool.size}^0^#{format("%.2f", total_paid)}^0.00"
          lines.join("\n")
        end

        def each_claim(mix, _system)
          mix.each do |code, count|
            count.times { |i| yield code, i }
          end
        end

        def obligation_line(index, patient_pool, vendor_pool, proc_code, date, billed)
          patient = patient_pool[index % patient_pool.size]
          vendor = vendor_pool[index % vendor_pool.size]
          paid_str = format("%.2f", billed) # paid = billed: this panel models a clinic paying full
          # provider billed charges today (no MLR repricing yet) — see
          # module doc for why that's the right pre-MLR baseline.
          "O^GM6-#{format("%04d", index)}^#{patient}^#{vendor}^#{proc_code}^" \
            "#{date.strftime("%Y%m%d")}^A^#{format("%.2f", billed)}^#{paid_str}^0.00^0.00^2026"
        end

        # Deterministic spread of `index` across [from, to] — no
        # randomness, so re-running the task is byte-for-byte
        # reproducible.
        def spread_date(from_y, from_m, from_d, to_y, to_m, to_d, index)
          from = Date.new(from_y, from_m, from_d)
          to = Date.new(to_y, to_m, to_d)
          span = (to - from).to_i
          from + (index * 37 % (span + 1))
        end

        # -- Output -------------------------------------------------------

        def print_headline(summary)
          savings = summary.total_overpayment_known
          pct = summary.total_paid.zero? ? 0 : (savings / summary.total_paid * 100)

          banner("HEADLINE NUMBER")
          puts "  Claims analyzed:        #{summary.obligations_analyzed}"
          puts "  Total billed (=paid):   $#{fmt(summary.total_paid)}"
          puts "  Total Medicare-Like Rate (MLR): $#{fmt(summary.total_medicare_equivalent)}"
          puts "  TOTAL ANNUAL PRC SAVINGS:       $#{fmt(savings)}  (~#{pct.round(1)}%)"
          puts
          puts "  \"We cut your PRC cost by $#{fmt(savings)} — about #{pct.round}% — " \
               "on this panel, just by repricing every purchased-care claim to Medicare-Like Rates.\""
          if summary.total_overpayment_stub_estimate.positive?
            puts
            puts "  (#{fmt(summary.total_overpayment_stub_estimate)} in additional stub_estimate " \
                 "dollars excluded from the headline number — not real-CMS-rate-backed.)"
          end

          # Data-source caveat, printed live: the MLR side is real CMS
          # data run through the real analyzer, but the billed charges
          # are synthetic (no real vendor invoice exists), so the % is
          # NOT measured from real provider charges. Keep this next to
          # the headline so the number is never quoted without it.
          puts
          puts "  Data-source caveat: billed charges in this panel are synthetic — no real"
          puts "  vendor invoice exists, so billed = MLR × BILLED_MULTIPLIER " \
               "(PFS #{BILLED_MULTIPLIER[:pfs]}×, OPPS #{BILLED_MULTIPLIER[:opps]}×, " \
               "IPPS #{BILLED_MULTIPLIER[:ipps]}×)."
          puts "  The MLR side is 100% real CMS data; the % above is a modeled recovery"
          puts "  rate, not one measured from real vendor charges. See"
          puts "  docs/gm6_mlr_savings_methodology.md."
        end

        def print_example_claims(summary)
          banner("EXAMPLE CLAIMS (full math)")
          [ "GM6-0071", "GM6-0281", "GM6-0299" ].each do |obligation_id|
            result = summary.results.find { |r| r.obligation_id == obligation_id }
            next unless result

            puts "  #{result.obligation_id}  [#{result.payment_system}]  #{result.procedure_description}"
            puts "    billed=$#{fmt(result.billed_amount)}  paid=$#{fmt(result.paid_amount)}  " \
                 "MLR=$#{fmt(result.medicare_equivalent)}  savings=$#{fmt(result.overpayment)}"
            puts "    rate_source=#{result.rate_source}  confidence=#{result.recovery_confidence}  " \
                 "release=#{result.rate_source_release}"
            puts
          end
        end

        def print_breakdown(summary)
          banner("BREAKDOWN BY PAYMENT SYSTEM")
          summary.results.group_by(&:payment_system).each do |system, results|
            billed = results.sum { |r| r.billed_amount.to_f }
            mlr = results.sum { |r| r.medicare_equivalent.to_f }
            savings = results.sum { |r| r.overpayment.to_f }
            puts "  #{system.to_s.upcase.ljust(6)} n=#{results.size.to_s.rjust(3)}  " \
                 "billed=$#{fmt(billed).rjust(12)}  mlr=$#{fmt(mlr).rjust(12)}  savings=$#{fmt(savings).rjust(12)}"
          end

          banner("RECOVERY CONFIDENCE (data-source honesty check)")
          summary.by_confidence.each { |confidence, count| puts "  #{confidence}: #{count}" }
          puts
        end

        def fmt(n)
          whole, cents = format("%.2f", n.to_f).split(".")
          "#{whole.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse}.#{cents}"
        end
      end
    end
  end
end
