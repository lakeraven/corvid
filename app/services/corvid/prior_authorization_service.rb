# frozen_string_literal: true

module Corvid
  # Determines whether a PRC referral requires prior authorization based
  # on cost thresholds, priority, and committee flags.
  class PriorAuthorizationService
    COST_THRESHOLD = 50_000.00
    NOTIFICATION_WINDOW_HOURS = 72

    AuthorizationResult = Struct.new(
      :authorization_type, :notification_deadline, :compliant,
      :within_notification_window, :requires_retroactive_authorization,
      :requires_prior_authorization, :requires_committee_review,
      :authorization_reason, :requires_case_manager, :has_case_manager,
      :message,
      keyword_init: true
    ) do
      def compliant?
        compliant
      end

      def within_notification_window?
        within_notification_window
      end

      def requires_retroactive_authorization?
        requires_retroactive_authorization
      end

      def requires_prior_authorization?
        requires_prior_authorization
      end

      def requires_committee_review?
        requires_committee_review
      end

      def requires_case_manager?
        requires_case_manager
      end

      def has_case_manager?
        has_case_manager
      end
    end

    class << self
      def required?(prc_referral)
        prc_referral.requires_committee?
      end

      def auto_authorizable?(prc_referral)
        !required?(prc_referral) && Corvid::AlternateResourceService.all_exhausted?(prc_referral)
      end

      def check(service_request)
        urgency = service_request.respond_to?(:urgency) ? service_request.urgency.to_s.upcase : "ROUTINE"
        is_emergent = urgency == "EMERGENT"
        requested_on = service_request.respond_to?(:requested_on) ? service_request.requested_on : Date.current
        auth_required = service_request.respond_to?(:authorization_required) ? service_request.authorization_required : false
        auth_reason = service_request.respond_to?(:authorization_reason) ? service_request.authorization_reason : nil
        estimated_cost = service_request.respond_to?(:estimated_cost) ? service_request.estimated_cost.to_f : 0
        committee_flag = service_request.respond_to?(:requires_committee_review) ? service_request.requires_committee_review : false
        case_manager = service_request.respond_to?(:case_manager_ien) ? service_request.case_manager_ien : nil

        if is_emergent
          check_emergency(requested_on, auth_required)
        else
          check_non_emergency(auth_required, auth_reason, estimated_cost, committee_flag, case_manager, urgency)
        end
      end

      private

      def check_emergency(requested_on, auth_required)
        deadline = requested_on + 3.days
        days_since = (Date.current - requested_on).to_i
        within_window = days_since <= 3
        needs_retro = !within_window

        messages = ["72-hour notification window"]
        messages << "retroactive authorization required" if needs_retro

        AuthorizationResult.new(
          authorization_type: :emergency,
          notification_deadline: deadline,
          compliant: within_window,
          within_notification_window: within_window,
          requires_retroactive_authorization: needs_retro,
          requires_prior_authorization: false,
          requires_committee_review: false,
          authorization_reason: nil,
          requires_case_manager: false,
          has_case_manager: false,
          message: messages.join("; ")
        )
      end

      def check_non_emergency(auth_required, auth_reason, estimated_cost, committee_flag, case_manager, urgency)
        needs_committee = committee_flag || estimated_cost >= COST_THRESHOLD
        needs_case_manager = needs_committee && case_manager.nil?
        has_cm = case_manager.present?

        messages = []
        compliant = true

        if auth_required
          messages << "Prior authorization required before service"
          if auth_reason.blank?
            messages << "authorization reason required"
            compliant = false
          end
        end

        if needs_committee
          messages << "committee review required"
          messages << "cost threshold exceeded" if estimated_cost >= COST_THRESHOLD
        end

        messages << "case manager required" if needs_case_manager

        AuthorizationResult.new(
          authorization_type: auth_required ? :prior : :none,
          notification_deadline: nil,
          compliant: compliant && !needs_case_manager,
          within_notification_window: true,
          requires_retroactive_authorization: false,
          requires_prior_authorization: auth_required,
          requires_committee_review: needs_committee,
          authorization_reason: auth_reason || (estimated_cost >= COST_THRESHOLD ? "cost threshold exceeded" : nil),
          requires_case_manager: needs_case_manager,
          has_case_manager: has_cm,
          message: messages.join("; ")
        )
      end
    end
  end
end
