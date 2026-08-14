# frozen_string_literal: true

require "corvid/adapter_factory"

module Corvid
  # Resolves the adapter for a tenant (optionally a specific facility), per
  # ADR 0006 Decision 4 / issue #390. This is the routed alternative to the
  # single static `Corvid.adapter` global: `AdapterRouter.resolve(tenant_id)`
  # looks up a Corvid::TenantConnectionConfig, resolves any secret reference
  # via Corvid.configuration.secret_reader, and builds an adapter instance
  # through Corvid::AdapterFactory — one call, cached with a short TTL.
  #
  # Additive by design (issue #462 / #390): this does NOT replace
  # `Corvid.adapter`, and it does NOT touch the ~20 model/service call
  # sites that read `Corvid.adapter` directly (that decoupling is #264,
  # tracked separately — see the TODO below). It introduces a second,
  # tenant-aware resolution path that hosts opt into per call site. When no
  # TenantConnectionConfig row exists for a tenant, resolve falls back to
  # the static `Corvid.adapter` global, so every existing single-tenant
  # caller (and the entire existing test suite, which sets
  # `Corvid.configuration.adapter` in test_helper.rb) keeps working
  # unchanged.
  #
  # TODO(#264): once models stop reading Corvid.adapter directly, the
  # natural next step is threading a resolved (tenant-scoped) adapter
  # through request/job context instead of each model reaching for a
  # global — at that point AdapterRouter.resolve becomes the thing that
  # global reads *through*, rather than a path most call sites can still
  # bypass. Out of scope here.
  module AdapterRouter
    Entry = Struct.new(:adapter, :expires_at)
    private_constant :Entry

    class << self
      # Resolves the adapter for +tenant_identifier+ (and optionally
      # +facility_identifier+). Cached for Corvid.configuration
      # .adapter_router_cache_ttl seconds; pass force: true to bypass the
      # cache and re-resolve (e.g. right after a credential rotation, in
      # addition to/instead of an explicit #invalidate call).
      def resolve(tenant_identifier, facility_identifier: nil, force: false)
        raise ArgumentError, "tenant_identifier is required" if tenant_identifier.nil?

        key = cache_key(tenant_identifier, facility_identifier)

        unless force
          cached = read_cache(key)
          return cached if cached
        end

        config = Corvid::TenantConnectionConfig.for(tenant_identifier, facility_identifier: facility_identifier)

        # No per-tenant config: fall back to the static global. Intentionally
        # not cached, so it always reflects the current Corvid.adapter (tests
        # reassign this constantly via test_helper.rb).
        return Corvid.adapter unless config

        adapter = Corvid::AdapterFactory.build(config)
        write_cache(key, adapter)
        adapter
      end

      # Busts the cache entry for one tenant/facility pair. Call this from a
      # credential-rotation or config-change webhook so the next #resolve
      # rebuilds rather than serving a stale adapter.
      def invalidate(tenant_identifier, facility_identifier: nil)
        mutex.synchronize { cache.delete(cache_key(tenant_identifier, facility_identifier)) }
        nil
      end

      # Clears every cached entry. Primarily a test helper.
      def invalidate_all!
        mutex.synchronize { cache.clear }
        nil
      end
      alias_method :reset!, :invalidate_all!

      private

      def read_cache(key)
        mutex.synchronize do
          entry = cache[key]
          entry && entry.expires_at > monotonic_now ? entry.adapter : nil
        end
      end

      def write_cache(key, adapter)
        mutex.synchronize do
          cache[key] = Entry.new(adapter, monotonic_now + ttl)
        end
      end

      def cache
        @cache ||= {}
      end

      def mutex
        @mutex ||= Mutex.new
      end

      def cache_key(tenant_identifier, facility_identifier)
        [ tenant_identifier.to_s, facility_identifier&.to_s ].freeze
      end

      def ttl
        Corvid.configuration.adapter_router_cache_ttl
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
