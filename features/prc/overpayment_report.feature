Feature: PRC overpayment report
  As a tribal health officer
  I need machine- and human-readable overpayment reports
  So that the council, IHS auditors, and recovery counterparties
  can each see the same provenance-cited numbers

  Background:
    Given a tenant "tnt_yakama" with persisted PRC analyses:
      | obligation_id | fiscal_year | vendor_id   | payment_system | recovery_confidence | overpayment |
      | OBL-100       | 2009        | VEND-HOSP   | ipps           | stub_estimate       | 24000       |
      | OBL-101       | 2010        | VEND-CLINIC | pfs            | clear               | 80          |

  Scenario: Summary CSV shows recoverable-now and directional totals separately
    When I export a summary CSV for "tnt_yakama"
    Then the CSV includes columns for total_overpayment_known and total_overpayment_excluded_stub
    And there is one row per fiscal_year + vendor_id + payment_system grouping

  Scenario: Detail CSV cites analyzer version and rate-source release on every row
    When I export a detail CSV for "tnt_yakama"
    Then every row carries analyzer_version, rate_source, and rate_source_release
    And every row carries the source_file the obligation was imported from

  Scenario: JSON export bundles summary, detail, filters, and generated_at
    When I export the report as JSON for "tnt_yakama" filtered to fiscal year 2010
    Then the JSON includes a generated_at timestamp
    And the JSON detail contains exactly the 2010 obligations
    And the JSON filters reflect the year filter

  Scenario: Confidence filter excludes stub-estimate rows for an audit-ready packet
    When I export a detail CSV for "tnt_yakama" filtered to recovery_confidence "clear"
    Then only obligations with clear-confidence analyses appear in the output
