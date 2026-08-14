# frozen_string_literal: true

module Corvid
  # Secret resolution for adapter credentials, per ADR 0006 Decision 3 /
  # issue #390.
  #
  # `TenantConnectionConfig#secret_ref` never stores a literal credential —
  # it stores an opaque reference (an ENV var name, a Vault path, an SSM
  # parameter name, etc.). A SecretReader turns that reference into the
  # actual secret value at resolution time, and only at resolution time:
  # AdapterRouter does not cache resolved secret values, only the adapter
  # instances built from them.
  module SecretReader
    # Abstract contract. Production hosts implement #fetch and wire it via
    #   Corvid.configure { |c| c.secret_reader = MyVaultReader.new }
    class Base
      # Returns the secret value for +secret_ref+, or raises if it cannot
      # be resolved. Implementations should fail loudly rather than return
      # nil — a silently-missing credential is worse than a startup crash.
      def fetch(secret_ref)
        raise NotImplementedError, "#{self.class}#fetch not implemented"
      end
    end

    # Default reader: treats +secret_ref+ as an ENV var name. This is the
    # right default for single-tenant / Mode 1 pilots (ADR 0006) and for
    # dev/test. Multi-tenant production hosts should plug a real secret
    # manager (Vault, AWS Secrets Manager, etc.) — ENV is not tenant-isolated
    # and does not support rotation without a process restart.
    class Env < Base
      def fetch(secret_ref)
        ENV.fetch(secret_ref.to_s) do
          raise KeyError,
                "Corvid::SecretReader::Env: ENV var #{secret_ref.to_s.inspect} is not set. " \
                "TenantConnectionConfig#secret_ref must name an ENV var when using the " \
                "default SecretReader, or configure a real secret manager via " \
                "Corvid.configure { |c| c.secret_reader = MyReader.new }."
        end
      end
    end
  end
end
