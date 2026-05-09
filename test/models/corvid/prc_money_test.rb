# frozen_string_literal: true

require "test_helper"

# Multi-currency tests for the PRC tables.
#
# Per ADR 0004:
# - Storage is integer subunit-cents (USD: cents, JOD: fils, SEK: öre, CAD: cents).
# - currency_iso is locked at write time and never updated.
# - Cross-currency arithmetic raises Money::Bank::UnknownRate / IncompatibleCurrencyError.
# - Reads return Money objects; the gem looks up subunit_to_unit from the ISO code.
class Corvid::PrcMoneyTest < ActiveSupport::TestCase
  TENANT_US     = "tnt_yakama"
  TENANT_SE     = "tnt_inera"
  TENANT_JO     = "tnt_hakeem"
  TENANT_CA     = "tnt_fndho"

  # -- Storage roundtrip across four currencies -------------------------------

  test "USD obligation stores cents and reads back as Money" do
    Corvid::TenantContext.with_tenant(TENANT_US) do
      ob = create_obligation("USD", billed: 65_000.00)
      assert_equal 6_500_000, ob.billed_amount_cents
      assert_equal "USD", ob.currency_iso
      assert_equal Money.from_amount(65_000, "USD"), ob.billed_amount
      assert_kind_of Money, ob.billed_amount
    end
  end

  test "SEK obligation stores öre (100 per krona) and reads back as Money" do
    Corvid::TenantContext.with_tenant(TENANT_SE) do
      ob = create_obligation("SEK", billed: 1_200.00)
      assert_equal 120_000, ob.billed_amount_cents
      assert_equal "SEK", ob.billed_amount.currency.iso_code
      assert_equal Money.from_amount(1_200, "SEK"), ob.billed_amount
    end
  end

  test "JOD obligation stores fils (1000 per dinar), not 100" do
    # Critical subunit assertion — hardcoding 100 anywhere would yield
    # 14_200 fils for 142 JOD (interpreting it as 142 cents) instead of
    # the correct 142_000 fils. The gem looks up the divisor by ISO code.
    Corvid::TenantContext.with_tenant(TENANT_JO) do
      ob = create_obligation("JOD", billed: 142.00)
      assert_equal 142_000, ob.billed_amount_cents,
                   "JOD's subunit_to_unit is 1000, not 100 — money-rails must look it up by ISO code"
      assert_equal "JOD", ob.billed_amount.currency.iso_code
      assert_equal Money.from_amount(142, "JOD"), ob.billed_amount
    end
  end

  test "CAD obligation stores cents (100 per dollar) and reads back as Money" do
    Corvid::TenantContext.with_tenant(TENANT_CA) do
      ob = create_obligation("CAD", billed: 350.50)
      assert_equal 35_050, ob.billed_amount_cents
      assert_equal "CAD", ob.billed_amount.currency.iso_code
    end
  end

  # -- Currency immutability --------------------------------------------------

  test "currency_iso defaults to USD on rows created without an explicit value" do
    Corvid::TenantContext.with_tenant(TENANT_US) do
      ob = Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-DEFAULT",
        imported_at: Time.current,
        billed_amount_cents: 100
      )
      assert_equal "USD", ob.currency_iso
    end
  end

  # -- Cross-currency safety --------------------------------------------------

  test "cross-currency arithmetic raises so apples-and-oranges sums fail loudly" do
    Corvid::TenantContext.with_tenant(TENANT_US) do
      usd_ob = create_obligation("USD", billed: 100)
      Corvid::TenantContext.with_tenant(TENANT_JO) do
        jod_ob = create_obligation("JOD", billed: 100, obligation_id: "OBL-JO-1")
        assert_raises(Money::Bank::UnknownRate) do
          usd_ob.billed_amount + jod_ob.billed_amount
        end
      end
    end
  end

  test "same-currency arithmetic across rows yields a Money in that currency" do
    Corvid::TenantContext.with_tenant(TENANT_SE) do
      a = create_obligation("SEK", billed: 100, obligation_id: "OBL-SE-A")
      b = create_obligation("SEK", billed: 250, obligation_id: "OBL-SE-B")
      total = a.billed_amount + b.billed_amount
      assert_equal Money.from_amount(350, "SEK"), total
      assert_equal "SEK", total.currency.iso_code
    end
  end

  # -- Currency immutability --------------------------------------------------

  test "currency_iso cannot be changed after a row is persisted" do
    Corvid::TenantContext.with_tenant(TENANT_US) do
      ob = create_obligation("USD", billed: 100, obligation_id: "OBL-LOCK-1")
      ob.currency_iso = "EUR"
      assert_raises(ActiveRecord::RecordInvalid) { ob.save! }
      ob.reload
      assert_equal "USD", ob.currency_iso, "the persisted value did not change"
    end
  end

  test "currency_iso immutability is enforced on PrcPayment too" do
    Corvid::TenantContext.with_tenant(TENANT_JO) do
      ob = create_obligation("JOD", billed: 1000, obligation_id: "OBL-LOCK-PMT")
      pmt = Corvid::PrcPayment.create!(
        prc_obligation: ob,
        payment_id: "PMT-LOCK-1",
        amount_cents: 100_000,
        currency_iso: "JOD"
      )
      pmt.currency_iso = "USD"
      assert_raises(ActiveRecord::RecordInvalid) { pmt.save! }
    end
  end

  test "currency_iso immutability is enforced on PrcOverpaymentAnalysis too" do
    Corvid::TenantContext.with_tenant(TENANT_CA) do
      ob = create_obligation("CAD", billed: 500, obligation_id: "OBL-LOCK-ANL")
      anl = Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_1.5",
        recovery_confidence: "clear",
        currency_iso: "CAD",
        analyzed_at: Time.current
      )
      anl.currency_iso = "USD"
      assert_raises(ActiveRecord::RecordInvalid) { anl.save! }
    end
  end

  # -- Payment + Analysis money fields ---------------------------------------

  test "PrcPayment monetizes amount with the row's currency" do
    Corvid::TenantContext.with_tenant(TENANT_JO) do
      ob = create_obligation("JOD", billed: 1000, obligation_id: "OBL-JO-PMT")
      pmt = Corvid::PrcPayment.create!(
        prc_obligation: ob,
        payment_id: "PMT-JO-1",
        amount_cents: 500_000, # 500 JOD = 500_000 fils
        currency_iso: "JOD"
      )
      assert_equal Money.from_amount(500, "JOD"), pmt.amount
    end
  end

  test "PrcOverpaymentAnalysis monetizes medicare_equivalent and overpayment" do
    Corvid::TenantContext.with_tenant(TENANT_CA) do
      ob = create_obligation("CAD", billed: 800, obligation_id: "OBL-CA-1")
      anl = Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_1.5",
        recovery_confidence: "clear",
        medicare_equivalent_cents: 50_000, # 500 CAD
        overpayment_cents: 30_000, # 300 CAD
        currency_iso: "CAD",
        analyzed_at: Time.current
      )
      assert_equal Money.from_amount(500, "CAD"), anl.medicare_equivalent
      assert_equal Money.from_amount(300, "CAD"), anl.overpayment
    end
  end

  private

  def create_obligation(currency, billed:, obligation_id: "OBL-#{currency}-#{SecureRandom.hex(4)}")
    Corvid::PrcObligation.create!(
      facility_identifier: "FAC-#{currency}",
      obligation_id: obligation_id,
      billed_amount: Money.from_amount(billed, currency),
      currency_iso: currency,
      fiscal_year: 2026,
      imported_at: Time.current
    )
  end
end
