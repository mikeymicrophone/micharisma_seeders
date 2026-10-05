# frozen_string_literal: true

module MICharismaSeeders
  class MICharismaEntityParser
    attr_reader :registry, :sequence, :namespace, :catalog, :adapter

    def self.select_entity_sequence(id, registry:, namespace: "MIC", catalog: nil, adapter: nil)
      new(registry: registry, namespace: namespace, catalog: catalog, adapter: adapter).select_entity_sequence(id)
    end

    def initialize(registry:, namespace: "MIC", catalog: nil, adapter: nil, sequence: nil)
      unless registry.is_a?(SequenceRegistry)
        raise ValidationError, "registry must be a SequenceRegistry"
      end
      [namespace, catalog].compact.each do |value|
        unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_]+\z/)
          raise ValidationError, "namespace/catalog must be a single string component"
        end
      end
      if adapter && !adapter.respond_to?(:resolve_sequence)
        raise ValidationError, "adapter must implement resolve_sequence(mapping)"
      end
      @registry, @namespace, @catalog, @adapter, @sequence = registry, namespace&.dup&.freeze, catalog&.dup&.freeze, adapter, sequence
      freeze
    end

    def select_entity_sequence(id)
      self.class.new(registry: registry, namespace: namespace, catalog: catalog, adapter: adapter, sequence: registry.fetch(id))
    end

    # A fully supplied code maps positionally. A shortened code supplies an
    # ordered subsequence; omitted slots must have known scope values. If more
    # than one resulting mapping is possible, there is no safe interpretation.
    def resolve(code, scope: {})
      raise UnknownSequenceError, "select an entity sequence before resolving a construction" unless sequence

      parts = components(code)
      known = Scope.normalize(scope)
      mapping = if parts.length == sequence.slots.length
                  sequence.slots.zip(parts).to_h
                elsif parts.length > sequence.slots.length
                  raise CodeError, "sequence #{sequence.id} accepts #{sequence.slots.length} components; received #{parts.length}"
                else
                  candidates = align(parts, known).uniq
                  if candidates.empty?
                    raise CodeError, "code does not supply sequence #{sequence.id}; missing slots need known scope values"
                  end
                  if candidates.length > 1
                    raise AmbiguousCodeError, "code has multiple interpretations under sequence #{sequence.id}; supply more components"
                  end
                  candidates.first
                end
      Scope.deep_freeze(mapping)
      adapter ? adapter.resolve_sequence(mapping) : mapping
    end

    private

    def components(code)
      unless code.is_a?(String) && code.match?(/\A[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*\z/)
        raise CodeError, "code must contain nonblank dash-delimited components using letters, numbers, and underscores"
      end
      parts = code.split("-")
      if namespace && parts.first.casecmp?(namespace)
        unless catalog && parts.length >= 3 && parts[1].casecmp?(catalog)
          raise CodeError, "qualified code must use #{namespace}-#{catalog || '(catalog required)'}"
        end
        parts = parts.drop(2)
      end
      parts
    end

    def align(parts, known)
      candidates = []
      visited = {}
      visit = lambda do |slot_index, part_index, mapping|
        state = [slot_index, part_index, mapping]
        return if visited.key?(state)

        visited[state] = true
        remaining_slots = sequence.slots.drop(slot_index)
        remaining_parts = parts.length - part_index
        return if remaining_parts > remaining_slots.length
        return if remaining_parts < remaining_slots.count { |slot| !known.key?(slot) }
        if slot_index == sequence.slots.length
          candidates << mapping if part_index == parts.length
          return
        end
        slot = sequence.slots[slot_index]
        default = known[slot]
        if default
          unless default.match?(/\A[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*\z/)
            raise CodeError, "scope #{slot} must contain a valid entity code or component for sequence lookup"
          end
          visit.call(slot_index + 1, part_index, mapping.merge(slot => default))
        end
        value = parts[part_index]
        if value && (!default || value.casecmp?(default))
          visit.call(slot_index + 1, part_index + 1, mapping.merge(slot => value))
        end
      end
      visit.call(0, 0, {})
      candidates
    end
  end

  # One context per input file/caller. No global parser selection is modified.
  class Context
    attr_reader :parser, :scope

    def initialize(registry:, namespace: "MIC", catalog: nil, adapter: nil, scope: {})
      @parser = MICharismaEntityParser.new(registry: registry, namespace: namespace, catalog: catalog, adapter: adapter)
      @scope = Scope.deep_freeze(Scope.normalize(scope))
    end

    def sequence_is(id)
      previous = @parser
      selected = @parser.select_entity_sequence(id)
      unless block_given?
        @parser = selected
        return self
      end
      @parser = selected
      begin
        yield self
      ensure
        @parser = previous
      end
    end

    def resolve(code, scope: {})
      parser.resolve(code, scope: @scope.merge(Scope.normalize(scope)))
    end
  end
end

::MICharismaEntityParser = MICharismaSeeders::MICharismaEntityParser unless defined?(::MICharismaEntityParser)
