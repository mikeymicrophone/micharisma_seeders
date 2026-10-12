# frozen_string_literal: true

require_relative "../micharisma_seeders"
require "schematist"
require "fileutils"

module MICharismaSeeders
  # Optional build tool: never loaded by the reader or parser entry points.
  # Catalog metadata comes from the consuming app, not this shared package.
  class SchemaExporter
    DRAFT = "https://json-schema.org/draft/2020-12/schema"
    # JSON Schema uses ECMA-style regexes; the lookahead prevents `$` from
    # accepting an identifier immediately before a trailing newline.
    END_PATTERN = "$(?![\\s\\S])"
    CODE_PATTERN = "^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*#{END_PATTERN}"
    NAME_PATTERN = "^[A-Za-z][A-Za-z0-9_]*#{END_PATTERN}"
    BASE_URL = "https://raw.githubusercontent.com/mikeymicrophone/athlete_ace_data/codex/yaml-seasonal-rosters/schemas/v1"

    def initialize(catalog: nil, base_url: BASE_URL)
      @catalog = catalog
      @base_url = base_url.delete_suffix("/")
    end

    def documents
      result = { "manifest.schema.json" => manifest, "entity-sequences.schema.json" => registry }
      result["#{@catalog.fetch('catalog').downcase}.schema.json"] = manifest(catalog: @catalog) if @catalog
      result
    end

    def write(directory, check: false)
      documents.each do |name, schema|
        path = File.join(directory, name)
        contents = JSON.pretty_generate(schema) + "\n"
        if check
          raise ValidationError, "stale published schema: #{path}" unless File.file?(path) && File.read(path) == contents
        else
          FileUtils.mkdir_p(directory)
          File.write(path, contents)
        end
      end
    end

    def manifest(catalog: nil)
      definitions = {
        "code" => { "type" => "string", "pattern" => CODE_PATTERN },
        "token" => { "type" => "string", "pattern" => "^[A-Za-z0-9_]+#{END_PATTERN}" },
        "scope" => { "type" => "object", "propertyNames" => { "pattern" => NAME_PATTERN },
          "additionalProperties" => { "anyOf" => [{ "type" => "string", "pattern" => "\\S" }, { "type" => "integer" }] } },
        "source" => { "type" => "object", "description" => "Optional source metadata; URLs and timestamps are not required." },
        "sequence" => sequence,
        "reference" => { "anyOf" => [ref("code"), object({
          "code" => ref("code"), "entity_sequence" => ref("sequence"), "scope" => ref("scope"),
          "namespace" => ref("token"), "catalog" => ref("token") }, required: %w[code])] }
      }
      common = { "scope" => ref("scope"), "source" => ref("source"), "entity_sequence" => ref("sequence") }
      record_fields = {
        "type" => { "type" => "string", "pattern" => NAME_PATTERN }, "code" => ref("code"),
        "aliases" => { "type" => "array", "items" => ref("code"), "uniqueItems" => true },
        "attributes" => { "type" => "object" },
        "references" => { "type" => "object", "additionalProperties" => ref("reference") }
      }.merge(common)
      verify_fields!(record_fields, Reader::RECORD_FIELDS)
      definitions["record"] = object(record_fields, required: %w[type code])
      if catalog
        definitions["record"]["oneOf"] = catalog.fetch("entities").sort.map do |name, entity|
          { "properties" => {
            "type" => { "const" => name },
            "attributes" => object(entity.fetch("attributes")),
            "references" => object(entity.fetch("references").to_h { |key| [key, ref("reference")] })
          } }
        end
        # Match the app adapter's stricter local canonical code syntax.
        definitions["localCode"] = { "type" => "string", "pattern" => "^[A-Z0-9]+(?:[-_][A-Z0-9]+)*#{END_PATTERN}",
          "not" => { "pattern" => "^#{catalog.fetch('namespace')}-#{catalog.fetch('catalog')}-" } }
        definitions["record"]["properties"]["code"] = ref("localCode")
        definitions["record"]["properties"]["aliases"]["items"] = ref("localCode")
      end
      containers = { "records" => { "type" => "array", "items" => ref("record") },
        "groups" => { "type" => "array", "items" => ref("group") } }
      group_fields = common.merge(containers)
      verify_fields!(group_fields, Reader::GROUP_FIELDS)
      definitions["group"] = object(group_fields)
      header_fields = { "format" => { "const" => Reader::FORMAT }, "namespace" => ref("token"),
        "catalog" => ref("token") }.merge(group_fields)
      verify_fields!(header_fields, Reader::HEADER_FIELDS)
      if catalog
        header_fields["namespace"] = { "const" => catalog.fetch("namespace") }
        header_fields["catalog"] = { "const" => catalog.fetch("catalog") }
      end
      name = catalog ? "#{catalog.fetch('catalog').downcase}.schema.json" : "manifest.schema.json"
      object(header_fields, required: %w[format namespace catalog]).merge(
        "$schema" => DRAFT, "$id" => "#{@base_url}/#{name}", "$defs" => definitions,
        "title" => catalog ? "#{catalog.fetch('catalog')} seed manifest v1" : "MICharisma seed manifest v1",
        "description" => "YAML and JSON input contract. Scope may be inherited; relationships and replay policy require application validation."
      )
    end

    def registry
      number = { "anyOf" => [{ "type" => "integer", "minimum" => 0, "maximum" => 99 },
        { "type" => "string", "pattern" => "^[0-9]{1,2}#{END_PATTERN}" }] }
      names = { "type" => "object", "propertyNames" => { "pattern" => NAME_PATTERN }, "additionalProperties" => number }
      { "$schema" => DRAFT, "$id" => "#{@base_url}/entity-sequences.schema.json", "title" => "Entity sequence registry v1",
        "type" => "object", "additionalProperties" => false,
        "patternProperties" => { "^[0-9]{1,2}#{END_PATTERN}" => { "type" => "object", "additionalProperties" => false,
          "patternProperties" => { "^[0-9]{1,2}#{END_PATTERN}" => { "type" => "array", "minItems" => 1, "uniqueItems" => true,
            "items" => { "type" => "string", "pattern" => NAME_PATTERN } } } } },
        "properties" => { "terminology" => object({ "families" => names, "sequences" => {
          "type" => "object", "additionalProperties" => false, "patternProperties" => { "^[0-9]{1,2}#{END_PATTERN}" => names } } }) } }
    end

    private

    def sequence
      part = { "anyOf" => [{ "type" => "integer", "minimum" => 0, "maximum" => 99 },
        { "type" => "string", "pattern" => "^(?:[0-9]{1,2}|[A-Za-z][A-Za-z0-9_]*)#{END_PATTERN}" }] }
      { "description" => "Numeric or named selection; staged family/member choices are interpreted by the reader.",
        "anyOf" => [{ "type" => "integer", "minimum" => 0, "maximum" => 99 },
          { "type" => "string", "pattern" => "^(?:[0-9]{1,2}_[0-9]{1,2}|[A-Za-z][A-Za-z0-9_]*)#{END_PATTERN}" },
          { "type" => "array", "minItems" => 1, "maxItems" => 2, "items" => part }] }
    end

    def object(properties, required: [])
      schema = Schematist::Schema.create do
        properties.each { |key, value| raw key, value, required: required.include?(key) }
      end.new.to_json_schema
      schema.reject { |key, _| %w[$schema title description].include?(key) }
    end

    def ref(name)
      { "$ref" => "#/$defs/#{name}" }
    end

    def verify_fields!(fields, expected)
      raise ValidationError, "schema fields drifted from Reader: #{expected.inspect}" unless fields.keys.sort == expected.sort
    end
  end
end
