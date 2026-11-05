# frozen_string_literal: true

# Issue #712: verify! requires adapters to echo date_of_service when the inquiry date is asked.
module EchoingVerifyEligibilityHelper
  def echo_verify_eligibility_date(result, date_of_service)
    return result unless date_of_service.instance_of?(Date)
    return result unless result.is_a?(Hash)
    return result unless result[:eligible] == true || result[:eligible] == false

    result.merge(date_of_service: date_of_service, date_of_service_defaulted: false)
  end
  # +custom+ may return nil or an unreadable hash; readable hashes get an echo when asked.
  def install_verify_eligibility_stub(calls: nil, eligible: false, &custom)
    Corvid.adapter.define_singleton_method(:verify_eligibility) do |patient_identifier, resource_type, date_of_service: nil|
      calls << [ patient_identifier, resource_type, date_of_service ] if calls

      base =
        if custom
          custom.call(patient_identifier, resource_type, date_of_service: date_of_service)
        else
          { eligible: eligible }
        end

      echo_verify_eligibility_date(base, date_of_service)
    end
  end
end
