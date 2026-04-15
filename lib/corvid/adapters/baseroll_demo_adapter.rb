# frozen_string_literal: true

require "corvid/adapters/mock_adapter"

module Corvid
  module Adapters
    # Demo adapter with realistic Yakama Nation enrollment data.
    # Proves the Baseroll -> Corvid integration contract for PRC
    # eligibility verification. Not a production adapter — real
    # Baseroll integration will use its API when available.
    class BaserollDemoAdapter < MockAdapter
      # Yakama reservation zip codes
      YAKAMA_RESERVATION_ZIPS = %w[98948 98951 98937 98952 98947].freeze

      private

      def seed!
        # Enrolled member — on reservation in Toppenish
        add_patient("pt_demo_enrolled",
          display_name: "SMARTLOWIT,MARY J",
          dob: Date.new(1985, 6, 15),
          sex: "F",
          ssn_last4: "4321",
          birthplace: "Toppenish, WA"
        )
        add_enrollment("pt_demo_enrolled",
          enrolled: true,
          membership_number: "YN-10042",
          tribe_name: "Yakama Nation",
          blood_quantum: "1/4",
          member_status: "enrolled"
        )
        add_residency("pt_demo_enrolled",
          on_reservation: true,
          address: "1205 S Elm St, Toppenish, WA 98948",
          service_area: "yakama"
        )

        # Non-enrolled person
        add_patient("pt_demo_nonenrolled",
          display_name: "JOHNSON,ROBERT T",
          dob: Date.new(1990, 3, 1),
          sex: "M",
          ssn_last4: nil
        )
        add_enrollment("pt_demo_nonenrolled",
          enrolled: false,
          membership_number: nil,
          tribe_name: nil,
          member_status: "denied"
        )
        add_residency("pt_demo_nonenrolled",
          on_reservation: false,
          address: "450 Pike St, Seattle, WA 98101",
          service_area: "seattle"
        )

        # Off-reservation enrolled member
        add_patient("pt_demo_off_reservation",
          display_name: "WILLIAMS,SARAH K",
          dob: Date.new(1978, 9, 22),
          sex: "F",
          ssn_last4: "8765",
          birthplace: "Wapato, WA"
        )
        add_enrollment("pt_demo_off_reservation",
          enrolled: true,
          membership_number: "YN-10098",
          tribe_name: "Yakama Nation",
          blood_quantum: "1/8",
          member_status: "enrolled"
        )
        add_residency("pt_demo_off_reservation",
          on_reservation: false,
          address: "2200 NE Broadway, Portland, OR 97232",
          service_area: "portland"
        )

        # Seed practitioners for demo
        add_practitioner("pr_demo_001",
          display_name: "FIANDER,VELMA C",
          npi: "1234567890",
          specialty: "PRC Manager"
        )
        add_practitioner("pr_demo_002",
          display_name: "SALUSKIN,KATHERINE M",
          npi: "0987654321",
          specialty: "Health Officer"
        )
      end
    end
  end
end
