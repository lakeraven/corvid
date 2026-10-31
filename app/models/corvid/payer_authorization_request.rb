# frozen_string_literal: true

module Corvid
  # A request to a payer for prior authorization. The payer's authorization
  # number is stored on this row and is never written to the referral's
  # PRC authorization_number: those are different decisions. An unknown or
  # missing decision is not an approval.
  class PayerAuthorizationRequest < ::ActiveRecord::Base
    self.table_name = "corvid_payer_authorization_requests"

    include TenantScoped

    CHANNELS = %w[pas x12_278 portal fax].freeze
    STATUSES = %w[
      drafted submitted pended approved partially_approved denied cancelled
    ].freeze
    # Statuses that mean the payer was asked. A draft was not sent. A
    # cancellation of a draft was not sent either, so cancelled is absent.
    SUBMISSION_STATUSES = %w[submitted pended approved partially_approved denied].freeze
    # Only these are approvals. Denied, cancelled, and anything else are not.
    APPROVAL_STATUSES = %w[approved partially_approved].freeze
    # Still waiting on the payer. Used by overdue; a decision is not overdue.
    AWAITING_DECISION_STATUSES = %w[submitted pended].freeze
    # Written when the payer is asked. Locked once that ask is stored.
    SUBMISSION_EVIDENCE = %i[submitted_at submitted_by_identifier follow_up_due_at].freeze
    # Written by an approval. A later cancellation keeps them.
    APPROVAL_EVIDENCE = %i[payer_authorization_identifier approved_from approved_to approved_units].freeze

    # from status => statuses a later save may enter. Missing keys and
    # empty lists allow nothing, so an unknown status cannot become an approval.
    TRANSITIONS = {
      "drafted" => %w[submitted cancelled].freeze,
      "submitted" => %w[pended approved partially_approved denied cancelled].freeze,
      "pended" => %w[approved partially_approved denied cancelled].freeze,
      "approved" => %w[cancelled].freeze,
      "partially_approved" => %w[cancelled].freeze,
      "denied" => [].freeze,
      "cancelled" => [].freeze
    }.freeze

    # Names the from status and the to status and nothing else. Status
    # values are the closed enum, not free text and not an identifier.
    class InvalidTransition < StandardError
      def initialize(from_status, to_status)
        super("#{from_status} -> #{to_status}")
      end
    end

    belongs_to :prc_referral, class_name: "Corvid::PrcReferral", optional: true

    # submit! and update!(status: "submitted") share this. The due time is
    # submitted_at plus the payer's turnaround, not the wall clock.
    before_validation :set_follow_up_due_at

    validates :payer_identifier, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validates :approved_units, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    validate :optional_identifiers_not_blank
    validate :submission_recorded_when_sent
    validate :submission_evidence_unchanged
    validate :approval_recorded_when_approved
    validate :approval_evidence_unchanged
    validate :approval_fields_match_status
    validate :approved_dates_in_order
    validate :status_follows_transitions
    validate :prc_referral_in_same_tenant

    # Follow-up is only open while the payer has not decided. Due at as_of
    # counts; a later timestamp does not. Rows with no timer are absent.
    # as_of must be a Time, a DateTime, or a TimeWithZone. A Date is
    # midnight and would move the boundary.
    scope :overdue, ->(as_of:) {
      unless as_of.is_a?(Time) || as_of.is_a?(DateTime)
        raise ArgumentError, "as_of must be a Time, DateTime, or ActiveSupport::TimeWithZone"
      end

      where(status: AWAITING_DECISION_STATUSES).where(follow_up_due_at: ..as_of)
    }

    # Inclusive on both ends: the day itself and the last day of `within`
    # are still inside the window. Denials and cancellations are not approvals
    # that can expire.
    scope :expiring, ->(within:, as_of:) {
      where(status: APPROVAL_STATUSES).where(approved_to: as_of..(as_of + within))
    }

    def self.transition_allowed?(from_status, to_status)
      targets = TRANSITIONS[from_status]
      targets.is_a?(Array) && targets.include?(to_status)
    end

    def submit!(submitted_by_identifier:, at: Time.current)
      raise ArgumentError, "submitted_by_identifier is required" if submitted_by_identifier.blank?
      raise ArgumentError, "submitted at is required" if at.blank?
      unless at.is_a?(Time) || at.is_a?(ActiveSupport::TimeWithZone)
        raise ArgumentError, "submitted at must be a Time"
      end

      apply_transition!("submitted") do
        self.submitted_at = at
        self.submitted_by_identifier = submitted_by_identifier
      end
    end

    def pend!
      apply_transition!("pended")
    end

    def approve!(payer_authorization_identifier:, approved_from:, approved_to:, approved_units: nil)
      require_approval!(payer_authorization_identifier, approved_from, approved_to, approved_units)
      apply_transition!("approved") do
        assign_approval(payer_authorization_identifier, approved_from, approved_to, approved_units)
      end
    end

    def partially_approve!(payer_authorization_identifier:, approved_from:, approved_to:, approved_units: nil)
      require_approval!(payer_authorization_identifier, approved_from, approved_to, approved_units)
      apply_transition!("partially_approved") do
        assign_approval(payer_authorization_identifier, approved_from, approved_to, approved_units)
      end
    end

    def deny!
      apply_transition!("denied")
    end

    def cancel!
      apply_transition!("cancelled")
    end

    # update_columns skips validations and hits the composite foreign key
    # directly. A violation aborts the surrounding PostgreSQL transaction,
    # so a caller that rescues it cannot keep using the connection. Roll
    # the write back to a savepoint; the row stays as it was.
    def update_columns(attributes)
      self.class.transaction(requires_new: true) { super }
    end

    private

    # Lock the row, then decide. Two callers can both read "submitted"
    # and both try to write; the second must observe the first decision
    # and refuse. Raising rolls the savepoint back, so a failure leaves
    # the stored row as it was. Rollback keeps the attempted assignment
    # in memory, so restore and reload until the object matches the row.
    def apply_transition!(to_status)
      with_lock do
        from_status = status
        unless self.class.transition_allowed?(from_status, to_status)
          raise InvalidTransition.new(from_status, to_status)
        end

        yield if block_given?
        self.status = to_status
        save!
        self
      end
    rescue StandardError
      restore_failed_transition!
      raise
    end

    def restore_failed_transition!
      restore_attributes
      reload if persisted?
    end

    # No duration for this payer means no timer. A non-duration is not a
    # turnaround; do not invent a due time. A blank submitted_at has no
    # start, so it also has no due time.
    def set_follow_up_due_at
      return unless will_save_change_to_status? && status == "submitted"

      self.follow_up_due_at = follow_up_due_at_for(submitted_at)
    end

    def follow_up_due_at_for(submitted_at)
      return if submitted_at.blank?

      turnarounds = Corvid.configuration.payer_authorization_turnarounds
      return unless turnarounds.is_a?(Hash)

      turnaround = turnarounds[payer_identifier]
      return unless turnaround.is_a?(ActiveSupport::Duration)

      submitted_at + turnaround
    end

    # Once the payer was asked, the ask cannot be rewritten. A new row's
    # status_in_database is the column default, and a draft was not sent.
    def submission_evidence_unchanged
      return unless submission_evidence_recorded?

      SUBMISSION_EVIDENCE.each do |name|
        errors.add(name, "can't be changed") if will_save_change_to_attribute?(name)
      end
    end

    def submission_evidence_recorded?
      return false if new_record?
      return false if status_in_database == "drafted"

      submitted_at_in_database.present?
    end

    # An approval's decision stays as it was recorded, including after
    # the request is cancelled. Cancelling a draft recorded nothing.
    def approval_evidence_unchanged
      return unless approval_evidence_recorded?

      APPROVAL_EVIDENCE.each do |name|
        errors.add(name, "can't be changed") if will_save_change_to_attribute?(name)
      end
    end

    def approval_evidence_recorded?
      return false if new_record?
      return true if APPROVAL_STATUSES.include?(status_in_database)

      status_in_database == "cancelled" && approval_evidence_in_database?
    end

    def approval_evidence_in_database?
      APPROVAL_EVIDENCE.any? { |name| attribute_in_database(name).present? }
    end

    # These columns are an approval, or a cancellation that kept one.
    # A cancellation cannot gain them, and no other status may hold them.
    def approval_fields_match_status
      return if approval_fields_allowed?

      APPROVAL_EVIDENCE.each do |name|
        errors.add(name, "must be blank") if self[name].present?
      end
    end

    def approval_fields_allowed?
      APPROVAL_STATUSES.include?(status) || (status == "cancelled" && approval_evidence_recorded?)
    end

    def require_approval!(payer_authorization_identifier, approved_from, approved_to, approved_units)
      if payer_authorization_identifier.blank? || approved_from.blank? || approved_to.blank?
        raise ArgumentError, "approval fields are required"
      end
      raise ArgumentError, "approved dates are invalid" if approved_to < approved_from
      return if approved_units.nil?
      return if approved_units.is_a?(Numeric) && approved_units.positive?

      raise ArgumentError, "approved units are invalid"
    end

    def assign_approval(payer_authorization_identifier, approved_from, approved_to, approved_units)
      self.payer_authorization_identifier = payer_authorization_identifier
      self.approved_from = approved_from
      self.approved_to = approved_to
      self.approved_units = approved_units
    end

    def optional_identifiers_not_blank
      %i[facility_identifier submitted_by_identifier payer_authorization_identifier].each do |name|
        value = self[name]
        next if value.nil?
        next if value.is_a?(String) && value.strip != ""

        errors.add(name, "can't be blank")
      end
    end

    def submission_recorded_when_sent
      return unless SUBMISSION_STATUSES.include?(status)

      errors.add(:submitted_at, "can't be blank") if submitted_at.blank?
      errors.add(:submitted_by_identifier, "can't be blank") if submitted_by_identifier.blank?
    end

    def approval_recorded_when_approved
      return unless APPROVAL_STATUSES.include?(status)

      errors.add(:payer_authorization_identifier, "can't be blank") if payer_authorization_identifier.blank?
      errors.add(:approved_from, "can't be blank") if approved_from.blank?
      errors.add(:approved_to, "can't be blank") if approved_to.blank?
    end

    def approved_dates_in_order
      return if approved_from.blank? || approved_to.blank?
      return if approved_to >= approved_from

      errors.add(:approved_to, "must not be before approved_from")
    end

    # Any save, including update!(status:), uses the same map as the
    # transition methods. status_in_database on a new row is the column
    # default, not a status anyone saved, so a new row may only be drafted.
    def status_follows_transitions
      if new_record?
        errors.add(:status, "is not an allowed change") unless status == "drafted"
        return
      end

      return unless will_save_change_to_status?
      return if self.class.transition_allowed?(status_in_database, status)

      errors.add(:status, "is not an allowed change")
    end

    # The tenant scope would hide another tenant's referral, and a hidden
    # row looks like "no referral". An assigned referral, including one
    # that has not been saved, is read from memory so it is not autosaved
    # before this check. Otherwise read the row by id with the scope off.
    # When that referral names a facility, this request must name the same
    # one, including when this request's facility is nil.
    def prc_referral_in_same_tenant
      return unless linked_referral?

      tenant, facility = linked_referral_tenant_and_facility
      if tenant != tenant_identifier
        errors.add(:prc_referral, "must belong to the same tenant")
        return
      end

      return if facility.blank? || facility == facility_identifier

      errors.add(:facility_identifier, "must match the linked referral")
    end

    def linked_referral?
      association(:prc_referral).target.present? || prc_referral_id.present?
    end

    def linked_referral_tenant_and_facility
      referral = association(:prc_referral).target
      if referral
        [ referral.tenant_identifier, referral.facility_identifier ]
      else
        Corvid::PrcReferral.unscoped.where(id: prc_referral_id).pick(:tenant_identifier, :facility_identifier)
      end
    end
  end
end
