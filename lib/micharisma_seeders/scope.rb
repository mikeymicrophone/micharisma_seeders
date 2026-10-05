# frozen_string_literal: true

module MICharismaSeeders
  module Scope
    module_function

    # Entity names are data, never evaluated as constants or class names.
    def key(value, location: nil)
      unless value.is_a?(String) || value.is_a?(Symbol)
        raise ValidationError.new("scope/sequence entity name must be a string", location: location)
      end
      name = value.to_s
      unless name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)
        raise ValidationError.new("invalid scope/sequence entity name #{name.inspect}", location: location)
      end
      name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
    end

    def normalize(value, location: nil)
      unless value.is_a?(Hash)
        raise ValidationError.new("scope must be a mapping", location: location)
      end
      value.each_with_object({}) do |(raw_key, raw_value), result|
        name = key(raw_key, location: location)
        if result.key?(name)
          raise DuplicateKeyError.new("duplicate normalized scope key #{name.inspect}", location: location)
        end
        unless (raw_value.is_a?(String) || raw_value.is_a?(Integer)) && !raw_value.to_s.strip.empty?
          raise ValidationError.new("scope #{name.inspect} must be a nonblank string or integer", location: location)
        end
        result[name] = raw_value.to_s
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |name, item| deep_freeze(name); deep_freeze(item) }
      when Array
        value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end
end
