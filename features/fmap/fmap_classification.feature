Feature: FMAP classification (rules-as-data, by date of service)
  Corvid classifies each encounter under the FMAP rules in force on its
  date of service, backed by evidence, so a state's CMS-64 claim is
  substantiated and misclassification is quantifiable. Marker issue #546.

  Background:
    Given a tenant "tnt_example" with the default FMAP rule set loaded
    And a facility "fac_uio_example" holding a "uio" facility authority

  Scenario: ARPA-window UIO encounter classifies at 100 percent
    When an encounter at "fac_uio_example" with date of service "2022-06-01" is classified for FMAP
    Then the FMAP category is "fmap_100_uio"
    And the applied rule citation includes "ARPA"

  Scenario: The same encounter after the ARPA window is regular FMAP
    When an encounter at "fac_uio_example" with date of service "2024-06-01" is classified for FMAP
    Then the FMAP category is "fmap_regular"

  Scenario: An unevidenced 638 encounter surfaces the gap, never a silent 100 percent
    Given a facility "fac_638_example" holding a "contract_638" facility authority
    When an unverified-AIAN encounter at "fac_638_example" with date of service "2026-03-01" is classified for FMAP
    Then the FMAP category is "fmap_regular"
    And the best available category is "fmap_100_ihs_638"
    And the missing evidence includes "aian_attestation"

  Scenario: An asserted 100 percent with no evidence chain is refused, not granted
    When an encounter at "fac_uio_example" with date of service "2022-06-01" is classified with AIAN asserted but no evidence
    Then the FMAP category is "fmap_regular"
    And the missing evidence includes "evidence_refs"

  Scenario: A claimed determination is immutable and corrections append
    When an encounter at "fac_uio_example" with date of service "2022-06-01" is classified and referenced by claim "clm_example_1"
    Then editing the determination is rejected as immutable
    And superseding it appends a correction linked from the original
