# frozen_string_literal: true

module Corvid
  # Maps RPMS PRC procedure descriptions to billing codes (HCPCS/CPT for
  # physician services, MS-DRG for inpatient hospital, APC for outpatient).
  #
  # PRC obligations name procedures in RPMS-internal shorthand
  # ("HIP_REPLACE_THR", "CARDIAC_CATH"), which is not directly billable code.
  # PrcOverpaymentAnalyzer needs the billing code to look up the Medicare-
  # equivalent rate. This dictionary is the bridge.
  #
  # Hosts can add custom mappings from an initializer:
  #
  #   Corvid::PrcProcedureDictionary.register(
  #     "MY_LOCAL_CODE",
  #     hcpcs: "12345",
  #     drg: "470",
  #     description: "Custom procedure"
  #   )
  module PrcProcedureDictionary
    Entry = Struct.new(:code, :hcpcs, :drg, :apc, :description, keyword_init: true)

    DEFAULTS = [
      # -- Major joint replacements (inpatient) -------------------------------
      {
        code: "HIP_REPLACE_THR", hcpcs: "27130", drg: "470",
        description: "Total hip arthroplasty"
      },
      {
        code: "HIP_REPLACE_PTL", hcpcs: "27125", drg: "470",
        description: "Partial hip arthroplasty (hemiarthroplasty)"
      },
      {
        code: "KNEE_REPLACE_TKA", hcpcs: "27447", drg: "470",
        description: "Total knee arthroplasty"
      },
      # -- Cardiac (inpatient) -----------------------------------------------
      {
        code: "CARDIAC_CATH", hcpcs: "93458", drg: "287",
        description: "Diagnostic cardiac catheterization, left heart"
      },
      {
        code: "CABG_3VESSEL", hcpcs: "33533", drg: "236",
        description: "Coronary artery bypass graft, 3-vessel"
      },
      # -- General surgery (inpatient/outpatient varies) ---------------------
      {
        code: "APPENDECTOMY", hcpcs: "44950", drg: "338",
        description: "Open appendectomy"
      },
      {
        code: "APPENDECTOMY_LAP", hcpcs: "44970", drg: "338",
        description: "Laparoscopic appendectomy"
      },
      {
        code: "GALLBLADDER_LAP", hcpcs: "47562", drg: "418",
        description: "Laparoscopic cholecystectomy"
      },
      # -- Common professional-only services --------------------------------
      {
        code: "OFFICE_VISIT_EST", hcpcs: "99213",
        description: "Office visit, established patient, low complexity"
      },
      {
        code: "OFFICE_VISIT_NEW", hcpcs: "99203",
        description: "Office visit, new patient, low complexity"
      }
    ].freeze

    class << self
      def register(code, hcpcs: nil, drg: nil, apc: nil, description: nil)
        ensure_loaded
        @entries[code.to_s] = Entry.new(
          code: code.to_s,
          hcpcs: hcpcs,
          drg: drg,
          apc: apc,
          description: description
        )
      end

      def lookup(code)
        ensure_loaded
        @entries[code.to_s]
      end

      def codes
        ensure_loaded
        @entries.keys
      end

      def reset!
        @entries = nil
        @loaded = false
        ensure_loaded
      end

      private

      def ensure_loaded
        return if @loaded

        @entries = {}
        DEFAULTS.each do |attrs|
          @entries[attrs[:code]] = Entry.new(**attrs)
        end
        @loaded = true
      end
    end
  end
end
