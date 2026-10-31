# frozen_string_literal: true

module Corvid
  # Which system bills a facility on a date of service. A null visit_type
  # covers every visit; a named visit_type covers only that type. One
  # tenant, facility, and visit type has a single system on any date.
  class BillingSystemSetting < ::ActiveRecord::Base
    self.table_name = "corvid_billing_system_settings"

    include TenantScoped

    # ADR 0002: string values, the same set the CHECK allows.
    SYSTEMS = %w[corvid ehr].freeze

    validates :facility_identifier, presence: true
    validates :system_of_record, presence: true, inclusion: { in: SYSTEMS }
    validates :effective_on, presence: true
    validate :visit_type_nil_or_present
    validate :expires_on_on_or_after_effective_on
    validate :no_overlapping_effective_range

    class << self
      # :corvid, :ehr, or :unknown. A visit-type row wins over the
      # all-visits row. A nil visit_type is untyped: the all-visits row
      # answers only when every applicable visit-type row names that
      # same system. A disagreement is unknown: an untyped claim might
      # be the visit the other system still bills. A String visit_type
      # that is blank after stripping, or any non-nil value that is not
      # a String, is unknown and never the all-visits answer. No row, a
      # blank facility, a blank tenant, or a value that is not a Date is
      # unknown. The query filters tenant_identifier itself, so the
      # answer stays that tenant's rows when the thread context differs.
      def system_of_record_for(
        facility_identifier:,
        visit_type:,
        on:,
        tenant_identifier: Corvid::TenantContext.current_tenant_identifier
      )
        return :unknown unless on.instance_of?(Date)
        return :unknown if facility_identifier.blank?
        return :unknown if tenant_identifier.blank?
        return :unknown unless visit_type.nil? || named_visit_type?(visit_type)

        rows = applicable_on(facility_identifier, on, tenant_identifier)
        return system_for_untyped(rows) if visit_type.nil?

        system_for_visit(rows, visit_type)
      end

      private

      # unscoped so TenantScoped's default scope cannot substitute the
      # thread tenant for the tenant this call named.
      def applicable_on(facility_identifier, on, tenant_identifier)
        unscoped.where(tenant_identifier: tenant_identifier)
          .where(facility_identifier: facility_identifier)
          .where(effective_on: ..on)
          .where("expires_on IS NULL OR expires_on >= ?", on)
          .to_a
      end

      def named_visit_type?(visit_type)
        visit_type.is_a?(String) && !visit_type.strip.empty?
      end

      def system_for_visit(rows, visit_type)
        row = rows.find { |candidate| candidate.visit_type == visit_type }
        row ||= rows.find { |candidate| candidate.visit_type.nil? }
        system_symbol(row)
      end

      def system_for_untyped(rows)
        all_visits = rows.find { |candidate| candidate.visit_type.nil? }
        return :unknown if all_visits.nil?
        return :unknown if visit_type_disagrees?(rows, all_visits.system_of_record)

        system_symbol(all_visits)
      end

      def visit_type_disagrees?(rows, system)
        rows.any? { |row| !row.visit_type.nil? && row.system_of_record != system }
      end

      def system_symbol(row)
        name = row&.system_of_record
        SYSTEMS.include?(name) ? name.to_sym : :unknown
      end
    end

    private

    # Scope attributes already copy the current tenant onto new records.
    # Replacing an explicit nil would make the presence check unreachable
    # inside a tenant context.
    def default_tenant_identifier_from_context
      return if tenant_identifier.nil? && tenant_identifier_came_from_user?

      super
    end

    # Null means all visit types. A whitespace-only value would collapse
    # to that same key under COALESCE(visit_type, '') in the exclusion
    # constraint, so it is rejected here and by the CHECK.
    def visit_type_nil_or_present
      return if visit_type.nil? || visit_type.match?(/[^ ]/)

      errors.add(:visit_type, "can't be blank")
    end

    def expires_on_on_or_after_effective_on
      return if expires_on.blank? || effective_on.blank? || expires_on >= effective_on

      errors.add(:expires_on, "must be on or after effective_on")
    end

    # Inclusive dates, matching daterange(..., '[]'). A null expires_on
    # runs forever. Nil visit_type is its own slice, not "any".
    def no_overlapping_effective_range
      return if facility_identifier.blank? || effective_on.blank?
      return unless overlapping_range?

      errors.add(:effective_on, "overlaps another range for this facility and visit type")
    end

    def overlapping_range?
      scope = self.class.where(
        tenant_identifier: tenant_identifier,
        facility_identifier: facility_identifier,
        visit_type: visit_type
      )
      scope = scope.where.not(id: id) if persisted?
      scope.where(overlap_sql, *overlap_binds).exists?
    end

    def overlap_sql
      if expires_on.nil?
        "expires_on IS NULL OR expires_on >= ?"
      else
        "effective_on <= ? AND (expires_on IS NULL OR expires_on >= ?)"
      end
    end

    def overlap_binds
      expires_on.nil? ? [ effective_on ] : [ expires_on, effective_on ]
    end
  end
end
