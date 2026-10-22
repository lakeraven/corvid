# frozen_string_literal: true

module Corvid
  # Asks whether an Indian health provider has determined that a person is
  # eligible for services from an Indian health provider, and appends a query
  # log row. The engine does not decide, and it stores no determination of
  # its own. See ADR 0009.
  #
  # A later inquiry for the same tenant and person replays the first
  # eligible or not_eligible answer and does not call the adapter. unknown
  # is asked again. A source that cannot be asked is logged as unavailable
  # and raised, not returned as an answer. The volume ceiling fails closed
  # and is applied before replay, under one per-tenant advisory lock.
  class IndianHealthEligibilityService
    class CeilingNotConfigured < StandardError; end

    class CeilingExceeded < StandardError
      attr_reader :message_id

      def initialize(message_id:)
        @message_id = message_id
        super("indian health eligibility inquiry ceiling exceeded")
      end
    end

    # Another inquiry for the tenant held the lock past LOCK_TIMEOUT. Nothing
    # is logged, so there is no message_id.
    class Busy < StandardError; end

    class SourceUnavailable < StandardError
      attr_reader :message_id

      def initialize(message_id:)
        @message_id = message_id
        super("indian health eligibility source is unavailable")
      end
    end

    PASS_THROUGH = %i[eligible not_eligible unknown].freeze
    DECISIVE = %w[eligible not_eligible].freeze
    LOCK_KEY_PREFIX = "corvid_indian_health_eligibility:"
    LOCK_SQL = "SELECT pg_advisory_xact_lock(hashtext(?))"
    LOCK_TIMEOUT = "5s"

    Result = Struct.new(
      :answer, :data_source, :asserted_at, :message_id, :replayed,
      keyword_init: true
    ) do
      def replayed?
        replayed
      end
    end

    def initialize(adapter:)
      @adapter = adapter
    end

    # Ceiling check through the log insert, under one per-tenant lock.
    # Refused and unavailable rows are committed, then raised outside the
    # transaction so the rollback does not drop them.
    def inquire(person_identifier:, requester_identifier:, agreement_reference:)
      validate!(person_identifier, requester_identifier, agreement_reference)
      outcome = IndianHealthEligibilityInquiry.transaction do
        lock_tenant!
        resolve(person_identifier, requester_identifier, agreement_reference)
      end
      raise outcome if outcome.is_a?(StandardError)

      outcome
    rescue ActiveRecord::LockWaitTimeout
      raise Busy, "another inquiry for this tenant is in progress"
    end

    private

    def validate!(person, requester, agreement)
      values = [ person, requester, agreement ]
      return if values.all? { |value| value.is_a?(String) && !value.strip.empty? }

      raise ArgumentError, "person_identifier, requester_identifier, and agreement_reference are required"
    end

    def lock_tenant!
      key = "#{LOCK_KEY_PREFIX}#{Corvid::TenantContext.require_tenant!}"
      connection = IndianHealthEligibilityInquiry.connection
      connection.execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
      connection.execute(IndianHealthEligibilityInquiry.sanitize_sql_array([ LOCK_SQL, key ]))
      connection.execute("SET LOCAL lock_timeout TO DEFAULT")
    end

    def resolve(person, requester, agreement)
      ceiling = configured_ceiling
      return refuse(person, requester, agreement) if over_ceiling?(requester, ceiling)

      prior = decisive_prior(person)
      return record(replay_attrs(prior), person, requester, agreement, replayed: true) if prior

      attrs = provider_attrs(person)
      return unavailable(person, requester, agreement) unless attrs

      record(attrs, person, requester, agreement, replayed: false)
    end

    def configured_ceiling
      ceiling = Corvid.configuration.indian_health_eligibility_ceiling
      limit = ceiling[:limit] if ceiling.is_a?(Hash)
      period = ceiling[:period] if ceiling.is_a?(Hash)
      return ceiling if limit.is_a?(Integer) && limit >= 0 && period.is_a?(ActiveSupport::Duration) && period.positive?

      raise CeilingNotConfigured, "indian_health_eligibility_ceiling is not configured"
    end

    def over_ceiling?(requester, ceiling)
      usage(requester, ceiling[:period]) >= ceiling[:limit]
    end

    def usage(requester, period)
      IndianHealthEligibilityInquiry
        .where(requester_identifier: requester, created_at: period.ago..)
        .where.not(answer: "refused")
        .count
    end

    def refuse(person, requester, agreement)
      logged = insert(REFUSED, person, requester, agreement, replayed: false)
      CeilingExceeded.new(message_id: logged.message_id)
    end

    def unavailable(person, requester, agreement)
      logged = insert(UNAVAILABLE, person, requester, agreement, replayed: false)
      SourceUnavailable.new(message_id: logged.message_id)
    end

    def decisive_prior(person_identifier)
      IndianHealthEligibilityInquiry
        .where(person_identifier: person_identifier, answer: DECISIVE)
        .order(:created_at, :id)
        .first
    end

    def replay_attrs(prior)
      {
        answer: prior.answer.to_sym,
        data_source: prior.data_source,
        asserted_at: prior.asserted_at
      }
    end

    def provider_attrs(person_identifier)
      response = fetch_provider(person_identifier)
      accepted_response(response) if response
    end

    # A savepoint, so an adapter whose own query fails does not abort the
    # transaction the unavailable row is written in.
    def fetch_provider(person_identifier)
      IndianHealthEligibilityInquiry.transaction(requires_new: true) do
        @adapter.indian_health_service_eligibility(person_identifier)
      end
    rescue StandardError, NotImplementedError
      nil
    end

    def accepted_response(response)
      return unless response.is_a?(Hash) && response[:confidence] == :verified

      determination = response[:determination]
      return unless PASS_THROUGH.include?(determination)
      return unknown_response(response) if determination == :unknown
      return unless decisive_provenance?(response)

      {
        answer: determination,
        data_source: response[:asserted_by],
        asserted_at: response[:determined_at]
      }
    end

    def unknown_response(response)
      asserted_by = response[:asserted_by]
      determined_at = response[:determined_at]
      return if !asserted_by.nil? && !asserted_by.is_a?(String)
      return if !determined_at.nil? && !time_like?(determined_at)

      { answer: :unknown, data_source: asserted_by, asserted_at: determined_at }
    end

    def decisive_provenance?(response)
      asserted_by = response[:asserted_by]
      asserted_by.is_a?(String) && !asserted_by.strip.empty? && time_like?(response[:determined_at])
    end

    def time_like?(value)
      value.respond_to?(:acts_like?) && value.acts_like?(:time)
    end

    def record(attrs, person, requester, agreement, replayed:)
      logged = insert(attrs, person, requester, agreement, replayed: replayed)
      Result.new(
        answer: attrs.fetch(:answer),
        data_source: attrs[:data_source],
        asserted_at: attrs[:asserted_at],
        message_id: logged.message_id,
        replayed: replayed
      )
    end

    def insert(attrs, person, requester, agreement, replayed:)
      IndianHealthEligibilityInquiry.create!(
        requester_identifier: requester,
        agreement_reference: agreement,
        person_identifier: person,
        answer: attrs.fetch(:answer).to_s,
        data_source: attrs[:data_source],
        asserted_at: attrs[:asserted_at],
        message_id: SecureRandom.uuid,
        replayed: replayed
      )
    end

    REFUSED = { answer: :refused, data_source: nil, asserted_at: nil }.freeze
    UNAVAILABLE = { answer: :unavailable, data_source: nil, asserted_at: nil }.freeze
    private_constant :PASS_THROUGH, :DECISIVE, :LOCK_KEY_PREFIX, :LOCK_SQL, :LOCK_TIMEOUT, :REFUSED, :UNAVAILABLE
  end
end
