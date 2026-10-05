# frozen_string_literal: true

module MICharismaSeeders
  Sequence = Struct.new(:id, :slots, keyword_init: true)
  SequenceSelection = Struct.new(:family, :member, keyword_init: true) do
    def complete?
      !member.nil?
    end

    def id
      "#{family}_#{member}" if complete?
    end
  end

  # Committed numeric recipes, independent of database primary keys. Registry
  # files contain the two-level mapping directly, without a seed header.
  class SequenceRegistry
    attr_reader :sequences

    def self.read(path)
      new(SafeDocument.read(path), location: path.to_s)
    end

    def self.normalize_id(*values, location: nil)
      selected = selection(*values, location: location)
      unless selected.complete?
        raise ValidationError.new("entity_sequence needs both a family and member", location: location)
      end
      selected.id
    end

    def self.selection(*values, family: nil, location: nil)
      values = values.first if values.length == 1 && values.first.is_a?(Array)
      if values.length == 2 && values.all? { |value| value.is_a?(Integer) }
        selected_family, member = values.map { |value| normalize_part(value, location: location) }
      elsif values.length == 1 && values.first.is_a?(String) && values.first.match?(/\A\d{1,2}_\d{1,2}\z/)
        selected_family, member = values.first.split("_").map { |value| normalize_part(value, location: location) }
      elsif values.length == 1 && values.first.is_a?(Integer)
        part = normalize_part(values.first, location: location)
        selected_family, member = family ? [normalize_part(family, location: location), part] : [part, nil]
      else
        raise ValidationError.new("entity_sequence accepts a string such as \"05_22\", two integers, or one staged integer", location: location)
      end
      SequenceSelection.new(family: selected_family.freeze, member: member&.freeze).freeze
    end

    def self.normalize_part(value, location: nil)
      unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\d{1,2}\z/))
        raise ValidationError.new("sequence family/member must be a decimal integer from 0 to 99", location: location)
      end
      number = value.is_a?(Integer) ? value : Integer(value, 10)
      unless number.between?(0, 99)
        raise ValidationError.new("sequence family/member must be from 0 to 99", location: location)
      end
      format("%02d", number)
    end

    def initialize(document = {}, location: "(registry)")
      unless document.is_a?(Hash)
        raise ValidationError.new("sequence registry must be a two-level mapping", location: location)
      end
      @sequences = {}
      families = {}
      document.each do |raw_family, members|
        next if raw_family == "terminology"
        family = self.class.normalize_part(raw_family, location: location)
        if families.key?(family)
          raise DuplicateKeyError.new("duplicate normalized sequence family #{family}", location: location)
        end
        families[family] = true
        unless members.is_a?(Hash)
          raise ValidationError.new("sequence family #{family} must be a mapping", location: location)
        end
        members.each do |raw_member, slots|
          member = self.class.normalize_part(raw_member, location: location)
          id = "#{family}_#{member}"
          if @sequences.key?(id)
            raise DuplicateKeyError.new("duplicate normalized sequence #{id}", location: location)
          end
          unless slots.is_a?(Array) && !slots.empty?
            raise ValidationError.new("sequence #{id} must be a nonempty entity-name array", location: location)
          end
          names = slots.map { |slot| Scope.key(slot, location: "#{location}.#{id}") }
          if names.uniq.length != names.length
            raise ValidationError.new("sequence #{id} contains repeated entity names; use distinct semantic names", location: location)
          end
          Scope.deep_freeze(names)
          @sequences[id] = Sequence.new(id: id.freeze, slots: names).freeze
        end
      end
      @families = Scope.deep_freeze(families.keys)
      configure_terminology(document.fetch("terminology", {}), location)
      @sequences.freeze
      freeze
    end

    def fetch(*values)
      selected = selection(*values)
      raise ValidationError, "entity_sequence needs both a family and member" unless selected.complete?

      normalized = selected.id
      sequences.fetch(normalized) do
        raise UnknownSequenceError, "unknown entity sequence #{normalized.inspect}"
      end
    end

    def validate_family!(value)
      family = family_number(value)
      raise UnknownSequenceError, "unknown entity sequence family #{family.inspect}" unless @families.include?(family)

      family.freeze
    end

    def selection(*values, family: nil, location: nil)
      values = values.first if values.length == 1 && values.first.is_a?(Array)
      if values.length == 2
        selected_family = family_number(values[0], location: location)
        member = member_number(selected_family, values[1], location: location)
        self.class.selection(Integer(selected_family, 10), Integer(member, 10), location: location)
      elsif values.length == 1 && named_part?(values.first)
        if family
          selected_family = validate_family!(family)
          member = member_number(selected_family, values.first, location: location)
          self.class.selection(Integer(selected_family, 10), Integer(member, 10), location: location)
        else
          selected_family = validate_family!(values.first)
          self.class.selection(Integer(selected_family, 10), location: location)
        end
      else
        self.class.selection(*values, family: family, location: location)
      end
    rescue Error => error
      raise error unless location && !error.location

      raise error.class.new(error.message, location: location)
    end

    private

    def configure_terminology(terms, location)
      unless terms.is_a?(Hash) && (terms.keys - %w[families sequences]).empty?
        raise ValidationError.new("terminology accepts families and sequences mappings", location: location)
      end
      @family_names = terminology_names(terms.fetch("families", {}), location) do |number|
        validate_family!(number)
      end
      @member_names = {}
      sequences = terms.fetch("sequences", {})
      raise ValidationError.new("terminology.sequences must be a family mapping", location: location) unless sequences.is_a?(Hash)

      sequences.each do |raw_family, names|
        family = self.class.normalize_part(raw_family, location: location)
        validate_family!(family)
        raise DuplicateKeyError.new("duplicate normalized terminology family #{family}", location: location) if @member_names.key?(family)

        @member_names[family] = terminology_names(names, location) do |number|
          member = self.class.normalize_part(number, location: location)
          unless @sequences.key?("#{family}_#{member}")
            raise UnknownSequenceError, "terminology identifies unknown entity sequence #{family}_#{member}"
          end
          member
        end
      end
      Scope.deep_freeze(@family_names)
      Scope.deep_freeze(@member_names)
    end

    def terminology_names(names, location)
      raise ValidationError.new("terminology names must be a mapping", location: location) unless names.is_a?(Hash)

      names.each_with_object({}) do |(name, number), normalized|
        key = Scope.key(name, location: location)
        raise DuplicateKeyError.new("duplicate normalized terminology name #{key}", location: location) if normalized.key?(key)

        normalized[key] = yield(number)
      end
    end

    def named_part?(value)
      (value.is_a?(String) || value.is_a?(Symbol)) && value.to_s.match?(/\A[A-Za-z]/)
    end

    def family_number(value, location: nil)
      return self.class.normalize_part(value, location: location) unless named_part?(value)

      name = Scope.key(value, location: location)
      (@family_names || {}).fetch(name) { raise UnknownSequenceError, "unknown entity sequence family name #{value.inspect}" }
    end

    def member_number(family, value, location: nil)
      return self.class.normalize_part(value, location: location) unless named_part?(value)

      name = Scope.key(value, location: location)
      @member_names.fetch(family, {}).fetch(name) { raise UnknownSequenceError, "unknown entity sequence name #{value.inspect} in family #{family}" }
    end
  end
end
