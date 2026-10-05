# frozen_string_literal: true

module MICharismaSeeders
  Sequence = Struct.new(:id, :slots, keyword_init: true)

  # Committed numeric recipes, independent of database primary keys. Registry
  # files contain the two-level mapping directly, without a seed header.
  class SequenceRegistry
    attr_reader :sequences

    def self.read(path)
      new(SafeDocument.read(path), location: path.to_s)
    end

    def self.normalize_id(id, location: nil)
      unless id.is_a?(String) && id.match?(/\A\d{1,2}_\d{1,2}\z/)
        raise ValidationError.new("entity_sequence must be a string such as \"01_10\"", location: location)
      end
      id.split("_").map { |part| format("%02d", Integer(part, 10)) }.join("_")
    end

    def initialize(document = {}, location: "(registry)")
      unless document.is_a?(Hash)
        raise ValidationError.new("sequence registry must be a two-level mapping", location: location)
      end
      @sequences = {}
      families = {}
      document.each do |raw_family, members|
        family = normalize_part(raw_family, location)
        if families.key?(family)
          raise DuplicateKeyError.new("duplicate normalized sequence family #{family}", location: location)
        end
        families[family] = true
        unless members.is_a?(Hash)
          raise ValidationError.new("sequence family #{family} must be a mapping", location: location)
        end
        members.each do |raw_member, slots|
          member = normalize_part(raw_member, location)
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
      @sequences.freeze
      freeze
    end

    def fetch(id)
      normalized = self.class.normalize_id(id)
      sequences.fetch(normalized) do
        raise UnknownSequenceError, "unknown entity sequence #{normalized.inspect}"
      end
    end

    private

    def normalize_part(value, location)
      unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\d{1,2}\z/))
        raise ValidationError.new("sequence family/member must be a decimal integer from 0 to 99", location: location)
      end
      number = value.is_a?(Integer) ? value : Integer(value, 10)
      unless number.between?(0, 99)
        raise ValidationError.new("sequence family/member must be from 0 to 99", location: location)
      end
      format("%02d", number)
    end
  end
end
