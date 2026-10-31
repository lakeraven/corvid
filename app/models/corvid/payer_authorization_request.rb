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

    validates :payer_identifier, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validates :approved_units, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    validate :optional_identifiers_not_blank
    validate :submission_recorded_when_sent
    validate :approval_recorded_when_approved
    validate :approved_dates_in_order
    validate :status_follows_transitions
    validate :prc_referral_in_same_tenant

    # Follow-up is only open while the payer has not decided. Due at as_of
    # counts; a later timestamp does not. Rows with no timer are absent.
    scope :overdue, ->(as_of:) {
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

      apply_transition!("submitted") do
        self.submitted_at = at
        self.submitted_by_identifier = submitted_by_identifier
        # No duration for this payer means no timer. A non-duration is
        # not a turnaround; do not invent a due time.
        self.follow_up_due_at = follow_up_due_at_for(at)
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

    private

    # Lock the row, then decide. Two callers can both read "submitted"
    # and both try to write; the second must observe the first decision
    # and refuse. Raising rolls the savepoint back, so a failure leaves
    # the stored row as it was.
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
    end

    def follow_up_due_at_for(submitted_at)
      turnarounds = Corvid.configuration.payer_authorization_turnarounds
      return unless turnarounds.is_a?(Hash)

      turnaround = turnarounds[payer_identifier]
      return unless turnaround.is_a?(ActiveSupport::Duration)

      submitted_at + turnaround
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
    # transition methods. status_in_database is the stored status. A new
    # row whose stored status is still nil may only start as drafted.
    def status_follows_transitions
      return unless will_save_change_to_status?

      from_status = status_in_database
      return if from_status.nil? && status == "drafted"
      return if self.class.transition_allowed?(from_status, status)

      errors.add(:status, "is not an allowed change")
    end

    # The tenant scope would hide another tenant's referral, and a hidden
    # row looks like "no referral". Read the row by id with the scope off
    # and compare tenant_identifier. When that referral names a facility,
    # this request must name the same one.
    def prc_referral_in_same_tenant
      return if prc_referral_id.blank?

      found = Corvid::PrcReferral.unscoped.where(id: prc_referral_id).pick(:tenant_identifier, :facility_identifier)
      if found.nil? || found.first != tenant_identifier
        errors.add(:prc_referral, "must belong to the same tenant")
        return
      end

      facility = found.last
      return if facility.blank?
      return if facility == facility_identifier

      errors.add(:facility_identifier, "must match the linked referral")
    end
  end
end
