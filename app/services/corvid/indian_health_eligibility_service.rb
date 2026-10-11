# frozen_string_literal: true

module Corvid
  # Asks whether an Indian health provider has determined that a person is
  # eligible for services from an Indian health provider, and appends a query
  # log row. The engine does not decide, and it does not keep enrollment,
  # descent, citizenship, or corporation shareholding. See ADR 0008.
  #
  # A later inquiry for the same tenant and person replays the first
  # eligible or not_eligible answer and does not call the adapter. unknown
  # and unavailable are asked again. The volume ceiling fails closed.
  class IndianHealthEligibilityService
    class CeilingNotConfigured < StandardError; end
    class CeilingExceeded < StandardError; end

    PASS_THROUGH = %i[eligible not_eligible unknown].freeze
    DECISIVE = %w[eligible not_eligible].freeze

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

    def inquire(person_identifier:, requester_identifier:, agreement_reference:)
      validate!(person_identifier, requester_identifier, agreement_reference)
      ceiling = configured_ceiling
      refuse_when_over!(ceiling, person_identifier, requester_identifier, agreement_reference)

      prior = decisive_prior(person_identifier)
      attrs = prior ? replay_attrs(prior) : read_provider(person_identifier)
      record(attrs, person_identifier, requester_identifier, agreement_reference, replayed: !prior.nil?)
    end

    private

    def validate!(person, requester, agreement)
      values = [ person, requester, agreement ]
      return if values.all? { |value| value.is_a?(String) && !value.strip.empty? }

      raise ArgumentError, "person_identifier, requester_identifier, and agreement_reference are required"
    end

    def configured_ceiling
      ceiling = Corvid.configuration.indian_health_eligibility_ceiling
      return ceiling if ceiling.is_a?(Hash) && !ceiling[:limit].nil? && !ceiling[:period].nil?

      raise CeilingNotConfigured, "indian_health_eligibility_ceiling is not configured"
    end

    def refuse_when_over!(ceiling, person, requester, agreement)
      return if usage(requester, ceiling[:period]) < ceiling[:limit]

      record(REFUSED, person, requester, agreement, replayed: false)
      raise CeilingExceeded, "indian health eligibility inquiry ceiling exceeded"
    end

    def usage(requester, period)
      IndianHealthEligibilityInquiry
        .where(requester_identifier: requester, created_at: period.ago..)
        .where.not(answer: "refused")
        .count
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

    def read_provider(person_identifier)
      response = @adapter.indian_health_service_eligibility(person_identifier)
      determination = response[:determination]
      return UNAVAILABLE if response[:confidence] == :unavailable
      return UNAVAILABLE unless PASS_THROUGH.include?(determination)

      {
        answer: determination,
        data_source: response[:asserted_by],
        asserted_at: response[:determined_at]
      }
    rescue StandardError, NotImplementedError
      UNAVAILABLE
    end

    def record(attrs, person, requester, agreement, replayed:)
      message_id = SecureRandom.uuid
      IndianHealthEligibilityInquiry.create!(
        requester_identifier: requester,
        agreement_reference: agreement,
        person_identifier: person,
        answer: attrs.fetch(:answer).to_s,
        data_source: attrs[:data_source],
        asserted_at: attrs[:asserted_at],
        message_id: message_id,
        replayed: replayed
      )
      Result.new(message_id: message_id, replayed: replayed, **attrs)
    end

    REFUSED = { answer: :refused, data_source: nil, asserted_at: nil }.freeze
    UNAVAILABLE = { answer: :unavailable, data_source: nil, asserted_at: nil }.freeze
    private_constant :REFUSED, :UNAVAILABLE
  end
end
