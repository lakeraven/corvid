# frozen_string_literal: true

require "corvid/adapters/mock_adapter"

module Corvid
  module Adapters
    # Demo adapter with synthetic enrollment data for PRC eligibility
    # verification demos. Proves the adapter contract works end-to-end.
    #
    # Production deployments wire a real enrollment adapter (e.g., a
    # tribal enrollment system) via the SaaS shell configuration.
    class EnrollmentDemoAdapter < MockAdapter
      private

      def seed!
        # Enrolled member — on reservation
        add_patient("pt_demo_enrolled",
          display_name: "DEMO,ENROLLED MEMBER",
          dob: Date.new(1985, 6, 15),
          sex: "F",
          ssn_last4: "4321",
          birthplace: "Test City, WA"
        )
        add_enrollment("pt_demo_enrolled",
          enrolled: true,
          membership_number: "TEST-10042",
          tribe_name: "Test Tribe",
          blood_quantum: "1/4",
          member_status: "enrolled"
        )
        add_residency("pt_demo_enrolled",
          on_reservation: true,
          address: "123 Main St, Test City, WA 99999",
          service_area: "test_service_area"
        )

        # Non-enrolled person
        add_patient("pt_demo_nonenrolled",
          display_name: "DEMO,NON ENROLLED",
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
          address: "450 First Ave, Other City, WA 98101",
          service_area: "other"
        )

        # Enrolled member — off reservation
        add_patient("pt_demo_off_reservation",
          display_name: "DEMO,OFF RESERVATION",
          dob: Date.new(1978, 9, 22),
          sex: "F",
          ssn_last4: "8765",
          birthplace: "Test City, WA"
        )
        add_enrollment("pt_demo_off_reservation",
          enrolled: true,
          membership_number: "TEST-10098",
          tribe_name: "Test Tribe",
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
          display_name: "DEMO,PRC MANAGER",
          npi: "0000000001",
          specialty: "PRC Manager"
        )
        add_practitioner("pr_demo_002",
          display_name: "DEMO,HEALTH OFFICER",
          npi: "0000000002",
          specialty: "Health Officer"
        )
      end
    end
  end
end
