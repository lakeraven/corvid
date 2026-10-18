# frozen_string_literal: true

# Synthetic test data only — not real state Medicaid policy.
# Registers two fictional state codes for the dummy app integration tests.

Corvid::StateMedicaidRules.register(
  "XA",
  expanded: true,
  groups: {
    expansion_adult: {
      renewal_months: 12,
      retro_coverage_months: 3,
      work_requirement: false
    },
    other: {
      renewal_months: 24,
      retro_coverage_months: 1,
      work_requirement: false
    }
  }
)

Corvid::StateMedicaidRules.register(
  "XB",
  expanded: false,
  work_requirement_programs: [
    {
      code: "xb_pathways",
      description_pattern: /\bTEST PATHWAYS\b/i
    }
  ],
  groups: {
    waiver_adult: {
      renewal_months: 12,
      retro_coverage_months: 2,
      work_requirement: true
    },
    other: {
      renewal_months: 12,
      retro_coverage_months: 2,
      work_requirement: false
    }
  }
)
