# frozen_string_literal: true

require "corvid/configuration"
require "corvid/fhir_reference"

module Corvid
  module Pas
    # Parses one PAS request Bundle in memory.
    #
    # The bundle can carry PHI, so this module keeps no class or global
    # cache and writes nothing to a log (ADR 0003). A rejection's
    # OperationOutcome is only an issue code, a FHIR element path, and a
    # fixed sentence — never a resource value, id, reference, fullUrl, or
    # non-element key.
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
      # Object keys allowed on an element path. The first other key stops
      # the path at the parent, so the key and anything under it stay out.
      FHIR_ELEMENT_NAME = /\A[a-z][A-Za-z0-9]*\z/
      RESTFUL_FULL_URL = %r{\A(.+)/([^/]+)/([^/]+)\z}

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
        full_url: "A Bundle entry fullUrl must match its resource type and id.",
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
        # Element path stopped at the parent of a non-element key.
        StoppedPath = Data.define(:text)

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
          bundle_issue || type_issue || entries_issue || shape_issue ||
            claim_issue || full_url_issue || duplicate_issue
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

        # After the Claim check and before duplicate detection. urn:uuid
        # and other non-RESTful fullUrls carry no type or id.
        def full_url_issue
          input_entries.each_with_index do |entry, index|
            problem = mismatched_full_url(entry, index)
            return problem if problem
          end
          nil
        end

        def mismatched_full_url(entry, index)
          type, id = url_type_and_id(entry["fullUrl"])
          return nil if type.nil? || same_resource?(entry["resource"], type, id)

          issue("invariant", "Bundle.entry[#{index}].fullUrl", :full_url)
        end

        def url_type_and_id(full_url)
          parts = restful_parts(full_url)
          return nil unless parts

          [ parts[1], parts[2] ]
        end

        def same_resource?(resource, type, id)
          same_text?(resource["resourceType"], type) && same_text?(resource["id"], id)
        end

        def duplicate_issue
          index = duplicate_entry
          return nil if index.nil?

          issue("duplicate", "Bundle.entry[#{index}]", :duplicate)
        end

        def bundle?
          @bundle.is_a?(Hash) && same_text?(@bundle["resourceType"], "Bundle")
        end

        def collection?
          same_text?(@bundle["type"], "collection")
        end

        def entry_list?
          list = input_entries
          list.is_a?(Array) && !list.empty?
        end

        def input_entries
          @bundle["entry"]
        end

        def claim?
          same_text?(input_entries[0]["resource"]["resourceType"], "Claim")
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
          return nil unless usable_string?(type) && usable_string?(id)

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
          @enqueued = { 0 => true }
          @visited = {}
          @problems = []
          visit_reachable
          return rejection_for if @problems.any?

          [ @references, @reachable ]
        end

        # Work queue plus visited and enqueued hashes. Resources are sorted
        # by entry index later, and rejection_for keeps the earliest problem,
        # so visit order does not change the result.
        def visit_reachable
          cursor = 0
          while cursor < @reachable.length
            index = @reachable[cursor]
            cursor += 1
            next if @visited[index]

            # Mark before walking so a cycle (A -> B -> A) does not revisit.
            @visited[index] = true
            scan_entry(index)
          end
        end

        def scan_entry(index)
          @scan_index = index
          @ordinal = 0
          status = each_reference(@entries[index].resource) do |reference, path|
            @ordinal += 1
            follow(index, @ordinal, reference, path)
          end
          @problems << [ index, @ordinal + 1, :nesting, nil ] if status == :deep
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
          index, _ordinal, kind, detail = earliest_problem
          code, expression, reason = rejection_parts(index, kind, detail)
          issue(code, expression, reason)
        end

        def earliest_problem
          @problems.min_by { |candidate| [ candidate[0], candidate[1] ] }
        end

        def rejection_parts(index, kind, detail)
          case kind
          when :nesting
            [ "structure", "Bundle.entry[#{index}]", :nesting ]
          when :contained
            [ "duplicate", contained_expression(index, detail), :duplicate ]
          else
            [ "not-found", reference_expression(index, detail), :not_found ]
          end
        end

        def contained_expression(index, contained_index)
          "Bundle.entry[#{index}].resource.contained[#{contained_index}]"
        end

        def reference_expression(index, path)
          prefix = "Bundle.entry[#{index}].resource"
          text = path_text(path)
          return prefix if text.empty?

          "#{prefix}.#{text}"
        end

        def enqueue(target)
          index = target.entry_index
          return if index.nil? || @enqueued[index]

          @enqueued[index] = true
          @reachable << index
        end

        def resolve(reference, entry)
          return nil unless usable_string?(reference)
          return contained_target(entry.resource, reference) if contained_reference?(reference)

          type, id = relative_type_and_id(reference)
          return relative_target(type, id, entry) if type

          # urn:uuid and absolute URLs match fullUrl exactly.
          located(reference)
        end

        def contained_reference?(reference)
          usable_string?(reference) && reference.start_with?("#")
        end

        # A relative Type/id is answered from the source entry's own base
        # only. Another server's copy of the same type and id is not it.
        # urn:uuid entries have no base, so the bundle's single type/id wins.
        def relative_target(type, id, entry)
          base = restful_base(entry.full_url)
          return located(restful_url(base, type, id)) if base
          return located_identity(type, id) if urn_uuid?(entry.full_url)

          nil
        end

        def restful_url(base, type, id)
          return nil unless joinable?(base, type) && joinable?(base, id)

          "#{base}/#{type}/#{id}"
        end

        def joinable?(left, right)
          usable_string?(left) && usable_string?(right) && Encoding.compatible?(left, right)
        end

        def contained_target(resource, reference)
          id = reference.delete_prefix("#")
          return nil unless valid_id?(id)

          list = resource["contained"]
          return nil unless list.is_a?(Array)

          match = list.find { |item| contained_item?(item, id) }
          return nil unless match

          # Contained resources are not Bundle entries, so they have no
          # entry index and stay out of the resources list.
          Target.new(resource: match, entry_index: nil)
        end

        def contained_item?(item, id)
          item.is_a?(Hash) && same_text?(item["id"], id)
        end

        def relative_type_and_id(reference)
          return nil unless usable_string?(reference)

          parts = reference.split("/", -1)
          return nil unless parts.length == 2 || parts.length == 4

          type, id, tail, version = parts
          return nil unless valid_type?(type) && valid_id?(id)
          return [ type, id ] if parts.length == 2
          return [ type, id ] if history_tail?(tail, version)

          nil
        end

        def history_tail?(tail, version)
          same_text?(tail, "_history") && valid_id?(version)
        end

        def restful_base(full_url)
          restful_parts(full_url)&.first
        end

        def restful_parts(full_url)
          return nil unless usable_string?(full_url)

          match = full_url.match(RESTFUL_FULL_URL)
          return nil unless match && restful_tail?(match)

          match.captures
        end

        def restful_tail?(match)
          valid_type?(match[2]) && valid_id?(match[3])
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

        # Match, split, compare, and interpolate only after this. An invalid
        # encoding, or one that is not ASCII-compatible, raises on those.
        def usable_string?(value)
          value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible?
        end

        def same_text?(left, right)
          return false unless usable_string?(left) && usable_string?(right)
          return false unless Encoding.compatible?(left, right)

          left == right
        end

        def nonblank_string?(value)
          usable_string?(value) && !value.match?(/\A[[:space:]]*\z/)
        end

        def fhir_element_name?(key)
          usable_string?(key) && key.ascii_only? && key.match?(FHIR_ELEMENT_NAME)
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
          record_duplicate_contained(value) if contained_list?(path, value)
          case value
          when Hash
            push_hash(stack, value, path, depth)
          when Array
            push_array(stack, value, path, depth)
          end
        end

        def contained_list?(path, value)
          value.is_a?(Array) && same_text?(path, "contained")
        end

        # Reachable entries only, ordered with unresolved references.
        # Entries that are never reached are not checked.
        def record_duplicate_contained(list)
          index = duplicate_contained_index(list)
          return if index.nil?

          @problems << [ @scan_index, @ordinal + 1, :contained, index ]
        end

        def duplicate_contained_index(list)
          seen = []
          list.each_with_index do |item, index|
            id = contained_item_id(item)
            next if id.nil?
            return index if seen.any? { |prior| same_text?(prior, id) }

            seen << id
          end
          nil
        end

        def contained_item_id(item)
          return nil unless item.is_a?(Hash)

          id = item["id"]
          id if usable_string?(id)
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
            stack.push([ :node, value[index], append_index(path, index), depth + 1 ])
          end
        end

        def append_index(path, index)
          return path if stopped_path?(path)

          "#{path}[#{index}]"
        end

        def frame_for(key, child, path, depth)
          if reference_value?(key, child)
            [ :ref, child, path, depth + 1 ]
          else
            [ :node, child, path, depth + 1 ]
          end
        end

        def reference_value?(key, child)
          child.is_a?(String) && reference_key?(key)
        end

        def reference_key?(key)
          fhir_element_name?(key) && key == "reference"
        end

        def extend_path(path, key)
          return path if stopped_path?(path)
          return stop_path(path) unless fhir_element_name?(key)

          join_segment(path, key)
        end

        def join_segment(path, key)
          text = path_text(path)
          return key if text.empty?

          "#{text}.#{key}"
        end

        def stop_path(path)
          StoppedPath.new(path_text(path))
        end

        def stopped_path?(path)
          path.is_a?(StoppedPath)
        end

        def path_text(path)
          stopped_path?(path) ? path.text : path
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
