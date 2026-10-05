# frozen_string_literal: true

module MICharismaSeeders
  Record = Struct.new(:type, :code, :aliases, :attributes, :references, :scope,
                      :namespace, :catalog, :source, :entity_sequence, :location,
                      keyword_init: true)

  class Reader
    FORMAT = "micharisma-seeds/v1"
    HEADER_FIELDS = %w[format namespace catalog scope source entity_sequence groups records].freeze
    GROUP_FIELDS = %w[scope source entity_sequence groups records].freeze
    RECORD_FIELDS = %w[type code aliases attributes references scope entity_sequence source].freeze

    def self.discover(paths)
      Array(paths).flat_map do |path|
        path = path.to_s
        File.directory?(path) ? Dir.glob(File.join(path, "**", "*.{json,yaml,yml}")) : path
      end.uniq.sort
    end

    def read(path)
      normalize(SafeDocument.read(path), path: path.to_s)
    end

    def read_string(text, format:, path: "(memory)")
      normalize(SafeDocument.parse(text, format: format, path: path), path: path)
    end

    def read_many(paths)
      self.class.discover(paths).flat_map { |path| read(path) }
    end

    private

    def normalize(document, path:)
      location = "#{path}:$"
      mapping!(document, location)
      fields!(document, HEADER_FIELDS, location)
      unless document["format"] == FORMAT
        raise ValidationError.new("format must be #{FORMAT.inspect}", location: location)
      end
      namespace = token!(document["namespace"], "namespace", location)
      catalog = token!(document["catalog"], "catalog", location)
      context = { scope: {}, source: nil, entity_sequence: nil }
      context = inherit(document, context, location)
      records = collect(document, context, namespace, catalog, location)
      records.freeze
    end

    def collect(container, context, namespace, catalog, location)
      records = array!(container.fetch("records", []), "records", location).each_with_index.map do |row, index|
        record(row, context, namespace, catalog, "#{location}.records[#{index}]")
      end
      array!(container.fetch("groups", []), "groups", location).each_with_index do |group, index|
        group_location = "#{location}.groups[#{index}]"
        mapping!(group, group_location)
        fields!(group, GROUP_FIELDS, group_location)
        records.concat(collect(group, inherit(group, context, group_location), namespace, catalog, group_location))
      end
      records
    end

    def record(row, inherited, namespace, catalog, location)
      mapping!(row, location)
      fields!(row, RECORD_FIELDS, location)
      context = inherit(row, inherited, location)
      type = string!(row["type"], "type", location)
      Scope.key(type, location: location)
      code = code!(row["code"], "code", location)
      aliases = array!(row.fetch("aliases", []), "aliases", location).map { |value| code!(value, "alias", location) }
      if aliases.uniq.length != aliases.length || aliases.include?(code)
        raise ValidationError.new("aliases must be distinct from each other and the preferred code", location: location)
      end
      attributes = row.fetch("attributes", {})
      references = row.fetch("references", {})
      mapping!(attributes, "#{location}.attributes")
      mapping!(references, "#{location}.references")
      string_keys!(attributes, "#{location}.attributes")
      string_keys!(references, "#{location}.references")
      references.each { |name, value| reference!(value, "#{location}.references.#{name}") }
      values = { type: type, code: code, aliases: aliases, attributes: attributes, references: references,
                 scope: context[:scope], namespace: namespace, catalog: catalog, source: context[:source],
                 entity_sequence: context[:entity_sequence], location: location }
      values.each_value { |value| Scope.deep_freeze(value) }
      Record.new(**values).freeze
    end

    def inherit(container, inherited, location)
      scope = inherited[:scope].merge(container.key?("scope") ? Scope.normalize(container["scope"], location: "#{location}.scope") : {})
      source = if container.key?("source")
                 mapping!(container["source"], "#{location}.source")
                 string_keys!(container["source"], "#{location}.source")
                 (inherited[:source] || {}).merge(container["source"])
               else
                 inherited[:source]
               end
      sequence = container.key?("entity_sequence") ? SequenceRegistry.normalize_id(container["entity_sequence"], location: location) : inherited[:entity_sequence]
      { scope: scope, source: source, entity_sequence: sequence }
    end

    def fields!(mapping, allowed, location)
      unsupported = mapping.keys - allowed
      return if unsupported.empty?

      raise ValidationError.new("unsupported fields: #{unsupported.map(&:inspect).join(', ')}", location: location)
    end

    def reference!(value, location)
      if value.is_a?(String)
        code!(value, "reference", location)
      elsif value.is_a?(Hash)
        fields!(value, %w[code entity_sequence scope namespace catalog], location)
        code!(value["code"], "reference code", location)
        if value.key?("entity_sequence")
          value["entity_sequence"] = SequenceRegistry.normalize_id(value["entity_sequence"], location: location)
        end
        value["scope"] = Scope.normalize(value["scope"], location: location) if value.key?("scope")
        %w[namespace catalog].each { |name| token!(value[name], name, location) if value.key?(name) }
      else
        raise ValidationError.new("reference must be a code string or mapping", location: location)
      end
    end

    def mapping!(value, location)
      raise ValidationError.new("expected a mapping", location: location) unless value.is_a?(Hash)

      value
    end

    def string_keys!(value, location)
      case value
      when Hash
        value.each do |name, item|
          raise ValidationError.new("mapping keys must be strings", location: location) unless name.is_a?(String)

          string_keys!(item, "#{location}.#{name}")
        end
      when Array
        value.each_with_index { |item, index| string_keys!(item, "#{location}[#{index}]") }
      end
    end

    def array!(value, name, location)
      raise ValidationError.new("#{name} must be an array", location: location) unless value.is_a?(Array)

      value
    end

    def string!(value, name, location)
      unless value.is_a?(String) && !value.strip.empty?
        raise ValidationError.new("#{name} must be a nonblank string", location: location)
      end
      value
    end

    def token!(value, name, location)
      string!(value, name, location)
      unless value.match?(/\A[A-Za-z0-9_]+\z/)
        raise ValidationError.new("#{name} must be one code component", location: location)
      end
      value
    end

    def code!(value, name, location)
      string!(value, name, location)
      unless value.match?(/\A[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*\z/)
        raise ValidationError.new("#{name} has invalid or blank components", location: location)
      end
      value
    end
  end
end
