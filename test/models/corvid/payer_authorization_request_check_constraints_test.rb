# frozen_string_literal: true

require "test_helper"

class Corvid::PayerAuthorizationRequestCheckConstraintsTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  PAYER_A = "payer_a"
  SIGNOFF = "pr_signoff_001"
  PAYER_AUTH_ID = "PAUTH-TEST-0001"

  teardown do
    Corvid.reset_configuration!
  end

  test "database rejects invalid channel via insert_all!" do
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(channel: "email")
      end
    end
  end

  test "database rejects invalid status via insert_all!" do
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(status: "waiting")
      end
    end
  end

  test "database rejects non-drafted row without submitted_at and submitted_by_identifier" do
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(status: "submitted", submitted_at: nil, submitted_by_identifier: nil)
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(status: "submitted", submitted_at: Time.current, submitted_by_identifier: "")
      end
    end
  end

  test "database rejects approved row missing payer authorization identifier or dates" do
    with_tenant(TENANT) do
      base = submitted_row_attrs

      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(base.merge(status: "approved", payer_authorization_identifier: nil))
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(base.merge(status: "approved", payer_authorization_identifier: "", approved_from: Date.current, approved_to: Date.current))
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(base.merge(status: "partially_approved", approved_from: nil, approved_to: Date.current))
      end
    end
  end

  test "database rejects approved_to before approved_from" do
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(
          submitted_row_attrs.merge(
            status: "approved",
            payer_authorization_identifier: PAYER_AUTH_ID,
            approved_from: Date.new(2026, 5, 10),
            approved_to: Date.new(2026, 5, 9)
          )
        )
      end
    end
  end

  test "database rejects non-positive approved_units" do
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(
          submitted_row_attrs.merge(
            status: "approved",
            payer_authorization_identifier: PAYER_AUTH_ID,
            approved_from: Date.new(2026, 5, 1),
            approved_to: Date.new(2026, 5, 31),
            approved_units: 0
          )
        )
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(
          submitted_row_attrs.merge(
            status: "approved",
            payer_authorization_identifier: PAYER_AUTH_ID,
            approved_from: Date.new(2026, 5, 1),
            approved_to: Date.new(2026, 5, 31),
            approved_units: -1
          )
        )
      end
    end
  end

  test "model validations mirror channel check constraint" do
    with_tenant(TENANT) do
      request = Corvid::PayerAuthorizationRequest.new(
        payer_identifier: PAYER_A,
        channel: "bogus",
        status: "drafted"
      )
      refute request.valid?
      assert request.errors[:channel].present?
    end
  end

  test "model validations mirror submitted metadata check constraint" do
    with_tenant(TENANT) do
      request = Corvid::PayerAuthorizationRequest.new(
        payer_identifier: PAYER_A,
        channel: "pas",
        status: "submitted",
        submitted_at: nil,
        submitted_by_identifier: nil
      )
      refute request.valid?
      assert request.errors[:status].present? || request.errors[:submitted_at].present?
    end
  end

  test "model validations mirror approval fields check constraint" do
    with_tenant(TENANT) do
      request = Corvid::PayerAuthorizationRequest.new(
        payer_identifier: PAYER_A,
        channel: "pas",
        status: "approved",
        submitted_at: Time.current,
        submitted_by_identifier: SIGNOFF,
        payer_authorization_identifier: nil,
        approved_from: Date.current,
        approved_to: Date.current
      )
      refute request.valid?
      assert request.errors[:payer_authorization_identifier].present? || request.errors[:status].present?
    end
  end

  test "database rejects denied row carrying approval fields via insert_all!" do
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        insert_row!(
          submitted_row_attrs.merge(
            status: "denied",
            payer_authorization_identifier: PAYER_AUTH_ID,
            approved_from: Date.new(2026, 5, 1),
            approved_to: Date.new(2026, 5, 31)
          )
        )
      end
    end
  end

  private

  def insert_row!(attrs)
    now = Time.current
    row = {
      tenant_identifier: TENANT,
      payer_identifier: PAYER_A,
      channel: "pas",
      status: "drafted",
      created_at: now,
      updated_at: now
    }.merge(attrs)
    Corvid::PayerAuthorizationRequest.unscoped.insert_all!([ row ])
  end

  def submitted_row_attrs
    {
      status: "submitted",
      submitted_at: Time.utc(2026, 3, 1, 10, 0, 0),
      submitted_by_identifier: SIGNOFF
    }
  end
end
