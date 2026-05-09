Feature: PRC obligations across international currencies
  As corvid expanding beyond US tribal IHS
  I need each tenant's monetary values stored in their own currency
  So that USD + JOD never silently sum, JOD's 1000 fils stays correct,
  and historical records are immutable across tenant reconfiguration

  # Per ADR 0004:
  # - Storage is integer subunit-cents (USD: 100/dollar, JOD: 1000/dinar,
  #   SEK: 100/krona, CAD: 100/dollar). The gem looks up the divisor by
  #   ISO 4217 code; nothing in corvid hardcodes "100".
  # - Cross-currency arithmetic raises by default, forcing reports to
  #   handle multi-currency explicitly.

  Scenario: Yakama Nation PRC obligation stores in USD cents
    Given a tenant "tnt_yakama" denominated in "USD"
    When I record a PRC obligation billed at 65000.00
    Then the obligation's billed_amount_cents is 6500000
    And the obligation's currency_iso is "USD"
    And reading the obligation back yields Money of 65000 USD

  Scenario: Inera Sweden tenant stores in SEK öre
    Given a tenant "tnt_inera" denominated in "SEK"
    When I record a PRC obligation billed at 1200.00
    Then the obligation's billed_amount_cents is 120000
    And the obligation's currency_iso is "SEK"
    And reading the obligation back yields Money of 1200 SEK

  Scenario: Jordan Hakeem tenant stores in JOD fils — 1000 per dinar, not 100
    Given a tenant "tnt_hakeem" denominated in "JOD"
    When I record a PRC obligation billed at 142.00
    Then the obligation's billed_amount_cents is 142000
    And the obligation's currency_iso is "JOD"
    And reading the obligation back yields Money of 142 JOD

  Scenario: FNDHO Ontario tenant stores in CAD cents
    Given a tenant "tnt_fndho" denominated in "CAD"
    When I record a PRC obligation billed at 350.50
    Then the obligation's billed_amount_cents is 35050
    And the obligation's currency_iso is "CAD"
    And reading the obligation back yields Money of 350.50 CAD

  Scenario: Cross-currency arithmetic raises rather than silently summing
    Given a tenant "tnt_yakama" denominated in "USD"
    And a tenant "tnt_hakeem" denominated in "JOD"
    When I try to add the USD obligation and the JOD obligation
    Then the engine raises a cross-currency error
