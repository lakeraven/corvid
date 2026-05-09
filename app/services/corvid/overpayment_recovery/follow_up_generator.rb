# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Generates a follow-up letter (courtesy reminder, FCA warning, or
    # escalation notice) given the original demand and how many days
    # have passed. Pairs with Timeline#follow_up_kind to decide which
    # one to emit.
    module FollowUpGenerator
      FollowUp = Struct.new(
        :kind,             # :courtesy_reminder | :fca_warning | :escalation
        :body,
        :references_original_demand,
        :warns_fca_liability,
        :mentions_treble_damages,
        :recommends_oig_referral,
        keyword_init: true
      )

      def self.generate(kind:, original_demand:)
        case kind
        when :courtesy_reminder
          courtesy(original_demand: original_demand)
        when :fca_warning
          # Defense in depth: Timeline.follow_up_kind already scopes
          # this branch to Section 506 demands, but if a non-Section-506
          # demand somehow reaches this kind we refuse to generate FCA
          # language rather than misapply the legal threat.
          unless original_demand.cites_section_506
            raise ArgumentError,
                  "FCA warning is only valid for Section 506 demands; got contractual"
          end
          fca_warning(original_demand: original_demand)
        when :final_notice
          final_notice(original_demand: original_demand)
        when :escalation
          escalation(original_demand: original_demand)
        else
          raise ArgumentError, "unknown follow-up kind: #{kind.inspect}"
        end
      end

      def self.courtesy(original_demand:)
        body = +"COURTESY REMINDER\n\n"
        body << "This is a courtesy reminder regarding the original demand letter dated #{(original_demand.return_deadline_date - original_demand.deadline_days).strftime('%Y-%m-%d')} "
        body << "for the overpayment of #{DemandLetterGenerator.format_money(original_demand.total_demanded)} to #{original_demand.provider_name}.\n"
        FollowUp.new(
          kind: :courtesy_reminder, body: body,
          references_original_demand: true,
          warns_fca_liability: false, mentions_treble_damages: false,
          recommends_oig_referral: false
        )
      end

      def self.fca_warning(original_demand:)
        body = +"FALSE CLAIMS ACT WARNING\n\n"
        body << "The 60-day deadline from the original demand has expired without resolution. "
        body << "This notice warns that continued non-payment may expose the provider to liability "
        body << "under the False Claims Act, 31 U.S.C. § 3729, including potential treble damages "
        body << "and per-claim penalties.\n"
        FollowUp.new(
          kind: :fca_warning, body: body,
          references_original_demand: true,
          warns_fca_liability: true, mentions_treble_damages: true,
          recommends_oig_referral: false
        )
      end

      def self.final_notice(original_demand:)
        body = +"FINAL NOTICE\n\n"
        body << "The deadline from the original demand has expired without resolution. "
        body << "If we do not receive payment shortly, we will refer this matter to counsel "
        body << "for collection action under the terms of the referral authorization.\n"
        FollowUp.new(
          kind: :final_notice, body: body,
          references_original_demand: true,
          warns_fca_liability: false,
          mentions_treble_damages: false,
          recommends_oig_referral: false
        )
      end

      def self.escalation(original_demand:)
        body = +"ESCALATION NOTICE\n\n"
        body << "This case has reached 90 days without resolution. We are escalating internally "
        body << "and recommend referral to the Office of Inspector General (OIG) or the tribal "
        body << "attorney for further action.\n"
        FollowUp.new(
          kind: :escalation, body: body,
          references_original_demand: true,
          # Escalation hands the matter off to counsel — it is not itself
          # an FCA warning. Keeping warns_fca_liability=false so any
          # downstream UI/report logic that filters on the flag matches
          # the body text.
          warns_fca_liability: false, mentions_treble_damages: false,
          recommends_oig_referral: true
        )
      end
    end
  end
end
