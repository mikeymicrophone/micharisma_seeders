# frozen_string_literal: true

require "json"
require "psych"
require "date"

module MICharismaSeeders
  # Parsing only: no interpolation, object construction, includes, or networking.
  module SafeDocument
    # Older JSON parsers build object_class instances directly. Do not subclass
    # Hash: native parsers may bypass an overridden Hash#[]= fast path.
    class StrictObject
      def initialize
        @values = {}
      end

      def []=(key, value)
        raise DuplicateKeyError, "duplicate key #{key.inspect}" if @values.key?(key)

        @values[key] = value
      end

      def [](key)
        @values[key]
      end

      def to_h
        @values.dup
      end
    end

    YAML_TAGS = %w[str int float bool null timestamp map seq].map { |name| "tag:yaml.org,2002:#{name}" }.freeze

    module_function

    def read(path)
      extension = File.extname(path.to_s).downcase
      format = { ".json" => :json, ".yaml" => :yaml, ".yml" => :yaml }[extension]
      raise ParseError.new("unsupported extension #{extension.inspect}", location: path.to_s) unless format

      parse(File.read(path, encoding: "UTF-8"), format: format, path: path.to_s)
    rescue SystemCallError => error
      raise ParseError.new(error.message, location: path.to_s)
    end

    def parse(text, format:, path: "(memory)")
      raise ParseError.new("ERB is unsupported", location: path) if text.include?("<%")

      data = case format.to_s.downcase
             when "json"
               # JSON.parse does not instantiate json_class additions. Unlike
               # JSON.load, it is safe by default; JSON 3 removed the redundant
               # create_additions option.
               # Recent JSON 2 versions convert object_class only after native
               # Hash construction, so the native duplicate check is required.
               # Earlier versions ignore this option and use StrictObject#[]=.
               JSON.parse(text, object_class: StrictObject, allow_duplicate_key: false)
             when "yaml", "yml"
               stream = Psych.parse_stream(text, filename: path)
               unless stream.children.length == 1
                 raise ParseError.new("expected exactly one YAML document", location: path)
               end
               inspect_yaml(stream, path, "$")
               # Standard YAML timestamps become portable strings below. Ruby
               # tags and all aliases are rejected before safe_load is called.
               Psych.safe_load(text, permitted_classes: [Date, Time], permitted_symbols: [], aliases: false, filename: path)
             else
               raise ParseError.new("unsupported format #{format.inspect}", location: path)
             end
      portable(data, path)
    rescue DuplicateKeyError => error
      raise error if error.location

      raise DuplicateKeyError.new(error.message, location: path)
    rescue JSON::ParserError => error
      # Recent JSON versions reject duplicates before object_class conversion.
      # Older versions reach StrictObject instead; expose one public error type.
      error_class = error.message.match?(/\Aduplicate key(?:\s|:)/) ? DuplicateKeyError : ParseError
      raise error_class.new(error.message, location: path)
    rescue Psych::Exception, EncodingError => error
      raise ParseError.new(error.message, location: path)
    end

    def inspect_yaml(node, path, pointer)
      location = "#{path}:#{node.start_line + 1}:#{node.start_column + 1} (#{pointer})"
      if node.is_a?(Psych::Nodes::Alias)
        raise ParseError.new("YAML aliases are unsupported", location: location)
      end
      if node.respond_to?(:tag) && node.tag && !YAML_TAGS.include?(node.tag)
        raise ParseError.new("unsupported YAML tag #{node.tag.inspect}", location: location)
      end
      if node.is_a?(Psych::Nodes::Mapping)
        seen = {}
        node.children.each_slice(2) do |key, value|
          unless key.is_a?(Psych::Nodes::Scalar)
            raise ParseError.new("mapping keys must be strings or integers", location: location)
          end
          inspect_yaml(key, path, pointer)
          decoded = yaml_key(key, location)
          if seen.key?(decoded)
            raise DuplicateKeyError.new("duplicate key #{decoded.inspect}", location: "#{path}:#{key.start_line + 1}:#{key.start_column + 1} (#{pointer})")
          end
          seen[decoded] = true
          inspect_yaml(value, path, "#{pointer}.#{decoded}")
        end
      elsif node.respond_to?(:children) && node.children
        node.children.each_with_index { |child, index| inspect_yaml(child, path, "#{pointer}[#{index}]") }
      end
    end

    def yaml_key(node, location)
      value = if node.quoted || node.tag == "tag:yaml.org,2002:str"
                node.value
              else
                Psych.safe_load(node.value, permitted_classes: [], permitted_symbols: [], aliases: false)
              end
      unless value.is_a?(String) || value.is_a?(Integer)
        raise ParseError.new("mapping keys must be strings or integers", location: location)
      end
      raise ParseError.new("YAML merge keys are unsupported", location: location) if value == "<<"

      value
    end

    def portable(value, location)
      case value
      when StrictObject
        portable(value.to_h, location)
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key] = portable(item, "#{location}.#{key}") }
      when Array
        value.each_with_index.map { |item, index| portable(item, "#{location}[#{index}]") }
      when Date, Time
        value.iso8601
      when String, Integer, TrueClass, FalseClass, NilClass
        value
      when Float
        raise ValidationError.new("non-finite number is unsupported", location: location) unless value.finite?

        value
      else
        raise ValidationError.new("unsupported value type #{value.class}", location: location)
      end
    end
  end
end
