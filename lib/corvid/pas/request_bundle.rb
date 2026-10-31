# frozen_string_literal: true

require "corvid/configuration"
require "corvid/fhir_reference"

module Corvid
  module Pas
    # Parses one PAS request Bundle in memory.
    #
    # The bundle can carry PHI, so this module keeps no class or global
    # cache and writes nothing to a log (ADR 0003). A rejection's
    # OperationOutcome is only an issue code, an element path, and a fixed
    # sentence — never a resource value, id, reference, or fullUrl.
    module RequestBundle
      class Error < StandardError; end

      Parsed = Data.define(:claim, :references, :resources) do
        def ok? = true
      end

      Rejected = Data.define(:operation_outcome) do
        def ok? = false
      end

      # Same type and id syntax as FhirReference. A relative reference that
      # fails these is unresolved, not an exception. Vault tokens are not
      # accepted here; an underscore is not a FHIR id.
      RESOURCE_TYPE = FhirReference::RESOURCE_TYPE
      ID_SYNTAX = FhirReference::ID_SYNTAX

      # Hostile nesting must not recurse without a bound. Real Claim
      # resources sit well under this.
      MAX_NESTING = 64

      DIAGNOSTICS = {
        bundle: "Input must be a FHIR Bundle resource.",
        bundle_type: "Bundle type must be collection.",
        entries: "Bundle must include at least one entry.",
        entry_element: "Each Bundle entry must include fullUrl and resource.",
        claim: "The first Bundle entry must be a Claim resource.",
        duplicate: "The same resource must not appear twice in the Bundle.",
        not_found: "A reference in the Bundle could not be resolved.",
        nesting: "A Bundle entry is nested too deeply to resolve."
      }.freeze

      def self.parse(input)
        Parser.new(input).call
      rescue StandardError => error
        # The rescued text may quote PHI, and Ruby would keep it reachable
        # through the cause chain. Sanitize and detach that chain.
        raise Error, Corvid.sanitize_phi(error.message), cause: nil
      end

      # One parse. Holds the copied bundle only for this call.
      class Parser
        Entry = Data.define(:index, :full_url, :resource)
        Target = Data.define(:resource, :entry_index)

        def initialize(input)
          # Copy before freeze so the caller's objects stay mutable and
          # independent of the graph we return.
          @bundle = copy_value(input)
        end

        def call
          invalid = validate
          return invalid if invalid

          index_entries
          collected = collect_references
          return collected if collected.is_a?(Rejected)

          build_parsed(*collected)
        end

        private

        def validate
          bundle_issue || type_issue || entries_issue || shape_issue || claim_issue || duplicate_issue
        end

        def bundle_issue
          issue("structure", "Bundle", :bundle) unless bundle?
        end

        def type_issue
          issue("value", "Bundle.type", :bundle_type) unless collection?
        end

        def entries_issue
          issue("required", "Bundle.entry", :entries) unless entry_list?
        end

        def shape_issue
          input_entries.each_with_index do |entry, index|
            problem = entry_issue(entry, index)
            return problem if problem
          end
          nil
        end

        def claim_issue
          issue("structure", "Bundle.entry[0].resource", :claim) unless claim?
        end

        def duplicate_issue
          index = duplicate_entry
          return nil if index.nil?

          issue("duplicate", "Bundle.entry[#{index}]", :duplicate)
        end

        def bundle?
          @bundle.is_a?(Hash) && @bundle["resourceType"] == "Bundle"
        end

        def collection?
          @bundle["type"] == "collection"
        end

        def entry_list?
          list = input_entries
          list.is_a?(Array) && !list.empty?
        end

        def input_entries
          @bundle["entry"]
        end

        def claim?
          input_entries[0]["resource"]["resourceType"] == "Claim"
        end

        def entry_issue(entry, index)
          prefix = "Bundle.entry[#{index}]"
          return element_issue(prefix) unless entry.is_a?(Hash)
          return element_issue("#{prefix}.fullUrl") unless nonblank_string?(entry["fullUrl"])
          return element_issue("#{prefix}.resource") unless entry["resource"].is_a?(Hash)

          nil
        end

        def element_issue(expression)
          issue("required", expression, :entry_element)
        end

        def duplicate_entry
          urls = {}
          identities = {}
          input_entries.each_with_index do |entry, index|
            return index if urls.key?(entry["fullUrl"]) || repeated_identity?(identities, entry)

            urls[entry["fullUrl"]] = true
            remember_identity(identities, entry)
          end
          nil
        end

        def repeated_identity?(identities, entry)
          key = identity_key(entry["resource"])
          !key.nil? && identities.key?(key)
        end

        def remember_identity(identities, entry)
          key = identity_key(entry["resource"])
          identities[key] = true if key
        end

        def identity_key(resource)
          type = resource["resourceType"]
          id = resource["id"]
          return nil unless type.is_a?(String) && id.is_a?(String)

          [ type, id ].freeze
        end

        def index_entries
          @by_url = {}
          @by_identity = {}
          @entries = input_entries.each_with_index.map { |entry, index| build_entry(entry, index) }
        end

        def build_entry(entry, index)
          record = Entry.new(index: index, full_url: entry["fullUrl"], resource: entry["resource"])
          @by_url[record.full_url] = record
          key = identity_key(record.resource)
          @by_identity[key] = record if key
          record
        end

        def collect_references
          @references = {}
          @reachable = [ 0 ]
          @visited = {}
          @problems = []
          visit_reachable
          return rejection_for if @problems.any?

          [ @references, @reachable ]
        end

        def visit_reachable
          loop do
            index = next_entry
            break if index.nil?

            # Mark before walking so a cycle (A -> B -> A) does not revisit.
            @visited[index] = true
            scan_entry(index)
          end
        end

        def next_entry
          @reachable.reject { |index| @visited[index] }.min
        end

        def scan_entry(index)
          ordinal = 0
          status = each_reference(@entries[index].resource) do |reference, path|
            ordinal += 1
            follow(index, ordinal, reference, path)
          end
          @problems << [ index, ordinal + 1, :nesting, nil ] if status == :deep
        end

        def follow(index, ordinal, reference, path)
          target = resolve(reference, @entries[index])
          if target.nil?
            @problems << [ index, ordinal, :missing, path ]
            return
          end

          # Keys are only strings written on the Claim, including contained
          # "#id" references. A later entry is still resolved and enqueued,
          # but its string must not enter the map or collide with a Claim key.
          if index.zero? && !@references.key?(reference)
            @references[reference] = target.resource
          end
          enqueue(target)
        end

        # Entry index first, then document order inside that entry, so a
        # later entry cannot hide an earlier unresolved reference.
        def rejection_for
          problem = @problems.min_by { |candidate| [ candidate[0], candidate[1] ] }
          index, _ordinal, kind, path = problem
          if kind == :nesting
            issue("structure", "Bundle.entry[#{index}]", :nesting)
          else
            issue("not-found", "Bundle.entry[#{index}].resource.#{path}", :not_found)
          end
        end

        def enqueue(target)
          index = target.entry_index
          return if index.nil? || @visited[index] || @reachable.include?(index)

          @reachable << index
        end

        def resolve(reference, entry)
          return nil unless usable_string?(reference)
          return contained_target(entry.resource, reference) if reference.start_with?("#")

          type, id = relative_type_and_id(reference)
          return relative_target(type, id, entry) if type

          # urn:uuid and absolute URLs match fullUrl exactly.
          located(reference)
        end

        # A relative Type/id is answered from the source entry's own base
        # only. Another server's copy of the same type and id is not it.
        # urn:uuid entries have no base, so the bundle's single type/id wins.
        def relative_target(type, id, entry)
          base = restful_base(entry.full_url)
          return located("#{base}/#{type}/#{id}") if base
          return located_identity(type, id) if urn_uuid?(entry.full_url)

          nil
        end

        def contained_target(resource, reference)
          id = reference.delete_prefix("#")
          return nil unless valid_id?(id)

          list = resource["contained"]
          return nil unless list.is_a?(Array)

          match = list.find { |item| item.is_a?(Hash) && item["id"] == id }
          return nil unless match

          # Contained resources are not Bundle entries, so they have no
          # entry index and stay out of the resources list.
          Target.new(resource: match, entry_index: nil)
        end

        def relative_type_and_id(reference)
          parts = reference.split("/", -1)
          return nil unless parts.length == 2 || parts.length == 4

          type, id, tail, version = parts
          return nil unless valid_type?(type) && valid_id?(id)
          return [ type, id ] if parts.length == 2
          return [ type, id ] if tail == "_history" && valid_id?(version)

          nil
        end

        def restful_base(full_url)
          return nil unless usable_string?(full_url)

          match = full_url.match(%r{\A(.+)/([^/]+)/([^/]+)\z})
          return nil unless match

          base, type, id = match.captures
          return nil unless valid_type?(type) && valid_id?(id)

          base
        end

        def urn_uuid?(full_url)
          usable_string?(full_url) && full_url.start_with?("urn:uuid:")
        end

        def located(url)
          target_for(@by_url[url])
        end

        def located_identity(type, id)
          target_for(@by_identity[[ type, id ]])
        end

        def target_for(record)
          return nil unless record

          Target.new(resource: record.resource, entry_index: record.index)
        end

        def valid_type?(value)
          usable_string?(value) && value.match?(RESOURCE_TYPE)
        end

        def valid_id?(value)
          usable_string?(value) && value.match?(ID_SYNTAX)
        end

        def usable_string?(value)
          value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible?
        end

        def nonblank_string?(value)
          usable_string?(value) && !value.match?(/\A[[:space:]]*\z/)
        end

        # Explicit stack so a deep or cyclic resource cannot blow the call
        # stack. References are yielded in document order.
        def each_reference(resource)
          seen = {}.compare_by_identity
          stack = [ [ :node, resource, "", 0 ] ]
          until stack.empty?
            kind, value, path, depth = stack.pop
            return :deep if depth > MAX_NESTING
            next if already_walked?(seen, kind, value)

            yield(value, path) if kind == :ref
            push_children(stack, value, path, depth) if kind == :node
          end
          nil
        end

        def already_walked?(seen, kind, value)
          return false unless kind == :node && container?(value)
          return true if seen.key?(value)

          seen[value] = true
          false
        end

        def push_children(stack, value, path, depth)
          case value
          when Hash
            push_hash(stack, value, path, depth)
          when Array
            push_array(stack, value, path, depth)
          end
        end

        # Push keys backward: the stack pops the last push first.
        def push_hash(stack, value, path, depth)
          value.keys.reverse_each do |key|
            child = value[key]
            child_path = extend_path(path, key)
            stack.push(frame_for(key, child, child_path, depth))
          end
        end

        def push_array(stack, value, path, depth)
          (value.length - 1).downto(0) do |index|
            stack.push([ :node, value[index], "#{path}[#{index}]", depth + 1 ])
          end
        end

        def frame_for(key, child, path, depth)
          if key == "reference" && child.is_a?(String)
            [ :ref, child, path, depth + 1 ]
          else
            [ :node, child, path, depth + 1 ]
          end
        end

        def extend_path(path, key)
          name = key.to_s
          return name if path.empty?

          "#{path}.#{name}"
        end

        def build_parsed(references, reachable)
          claim = @entries[0].resource
          resources = reachable.reject(&:zero?).uniq.sort.map { |index| @entries[index].resource }
          freeze_graph(claim)
          freeze_graph(references)
          freeze_graph(resources)
          Parsed.new(claim: claim, references: references, resources: resources)
        end

        def issue(code, expression, reason)
          Rejected.new(operation_outcome: outcome_for(code, expression, DIAGNOSTICS.fetch(reason)))
        end

        def outcome_for(code, expression, diagnostics)
          freeze_graph({
            "resourceType" => "OperationOutcome",
            "issue" => [
              {
                "severity" => "error",
                "code" => code,
                "expression" => [ expression ],
                "diagnostics" => diagnostics
              }
            ]
          })
        end

        def copy_value(value)
          return value.dup if value.is_a?(String)
          return value unless container?(value)

          shells = {}.compare_by_identity
          pending = [ value ]
          until pending.empty?
            node = pending.pop
            next if shells.key?(node)

            shells[node] = node.is_a?(Hash) ? {} : []
            queue_nested(node, pending)
          end
          fill_copies(shells)
          shells[value]
        end

        def queue_nested(node, pending)
          if node.is_a?(Hash)
            node.each do |key, child|
              pending << key if container?(key)
              pending << child if container?(child)
            end
          else
            node.each { |child| pending << child if container?(child) }
          end
        end

        def fill_copies(shells)
          shells.each { |node, copy| fill_container(node, copy, shells) }
        end

        def fill_container(node, copy, shells)
          if node.is_a?(Hash)
            node.each { |key, child| copy[copied_child(key, shells)] = copied_child(child, shells) }
          else
            node.each { |child| copy << copied_child(child, shells) }
          end
        end

        def copied_child(value, shells)
          return shells[value] if shells.key?(value)
          return value.dup if value.is_a?(String)

          value
        end

        def container?(value)
          value.is_a?(Hash) || value.is_a?(Array)
        end

        def freeze_graph(value)
          seen = {}.compare_by_identity
          pending = [ value ]
          until pending.empty?
            node = pending.pop
            next if seen.key?(node)

            seen[node] = true
            freeze_node(node, pending)
          end
          value
        end

        def freeze_node(node, pending)
          case node
          when Hash
            node.each do |key, child|
              pending << key
              pending << child
            end
            node.freeze
          when Array
            node.each { |child| pending << child }
            node.freeze
          when String
            node.freeze
          end
        end
      end
      private_constant :Parser
    end
  end
end
