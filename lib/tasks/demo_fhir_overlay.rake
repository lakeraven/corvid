# frozen_string_literal: true

# Corvid overlay via STOCK FHIR — multi-clinic PRC + MLR demo.
#
# A consortium of two synthetic clinics (on different source EHRs) exports
# plain FHIR R4. Corvid ingests each via the generic FhirAdapter (no vendor
# code), runs PRC eligibility, reprices purchased-care to Medicare-Like Rates
# with the unchanged analyzer, and reports per-clinic + consortium dollars
# recovered. CEHRT-safe: the certified EHR stays the system of record.
#
#   bundle exec rails demo:overlay
#   bundle exec rails demo:overlay_reset
namespace :demo do
  desc "Corvid stock-FHIR overlay demo: ingest 2 synthetic clinics over FHIR R4, run PRC + MLR, report $ recovered"
  task overlay: :environment do
    require "corvid/demo/fhir_overlay_demo"
    Corvid::Demo::FhirOverlayDemo.run
  end

  desc "Reset the stock-FHIR overlay demo (delete ingested cases/obligations for both synthetic tenants)"
  task overlay_reset: :environment do
    require "corvid/demo/fhir_overlay_demo"
    Corvid::Demo::FhirOverlayDemo.reset!
  end
end
