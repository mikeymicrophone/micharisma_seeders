# frozen_string_literal: true

require "minitest/autorun"
require "json_schemer"
require "tmpdir"
require "open3"
require_relative "../lib/micharisma_seeders/schema_exporter"

class SchemaExporterTest < Minitest::Test
  def exporter
    MICharismaSeeders::SchemaExporter.new(catalog: {
      "namespace" => "MIC", "catalog" => "ALA", "entities" => {
        "Player" => { "attributes" => { "first_name" => { "type" => "string" } }, "references" => %w[team sport] }
      }
    })
  end

  def document
    { "format" => "micharisma-seeds/v1", "namespace" => "MIC", "catalog" => "ALA",
      "scope" => { "sport" => "SPORT-BKT" }, "groups" => [{ "scope" => { "team" => "TEAM-NYK" },
        "groups" => [{ "records" => [{ "type" => "Player", "code" => "PLAYER-HART_JOSH", "attributes" => { "first_name" => "Josh" } }] }] }] }
  end

  def test_schemas_are_valid_and_export_is_deterministic_with_drift_detection
    exporter.documents.each_value { |schema| assert JSONSchemer.valid_schema?(schema) }
    Dir.mktmpdir do |directory|
      exporter.write(directory)
      exporter.write(directory, check: true)
      path = File.join(directory, "ala.schema.json")
      File.write(path, "{}")
      assert_raises(MICharismaSeeders::ValidationError) { exporter.write(directory, check: true) }
    end
  end

  def test_yaml_and_json_with_nested_scopes_are_accepted_by_reader_and_schema
    schema = JSONSchemer.schema(exporter.documents.fetch("ala.schema.json"))
    [[:yaml, Psych.dump(document)], [:json, JSON.generate(document)]].each do |format, text|
      parsed = MICharismaSeeders::SafeDocument.parse(text, format: format)
      assert schema.valid?(parsed), schema.validate(parsed).to_a.inspect
      row = MICharismaSeeders::Reader.new.read_string(text, format: format).first
      assert_equal({ "sport" => "SPORT-BKT", "team" => "TEAM-NYK" }, row.scope)
    end
  end

  def test_reader_and_shared_schema_agree_on_accepted_and_rejected_document_shapes
    schema = JSONSchemer.schema(exporter.documents.fetch("manifest.schema.json"))
    [document, document.merge("source" => {}), document.merge("records" => [])].each do |value|
      assert schema.valid?(value)
      MICharismaSeeders::Reader.new.read_string(JSON.generate(value), format: :json)
    end
    [document.merge("format" => "mic-seed-proposal/1"), document.merge("bogus" => true), document.merge("source" => nil),
     document.merge("scope" => { "team" => false }), document.merge("records" => [{ "type" => "Player" }])].each do |value|
      refute schema.valid?(value)
      assert_raises(MICharismaSeeders::Error) { MICharismaSeeders::Reader.new.read_string(JSON.generate(value), format: :json) }
    end
  end

  def test_catalog_disallows_foreign_types_numeric_ids_bad_attributes_and_reference_names
    schema = JSONSchemer.schema(exporter.documents.fetch("ala.schema.json"))
    [ { "type" => "Missing", "code" => "PLAYER-HART" },
      { "type" => "Player", "code" => "PLAYER-HART", "attributes" => { "team_id" => 1 } },
      { "type" => "Player", "code" => "PLAYER-HART", "attributes" => { "first_name" => 1 } },
      { "type" => "Player", "code" => "PLAYER-HART", "references" => { "wrong" => "TEAM-NYK" } },
      { "type" => "Player", "code" => "MIC-ALA-PLAYER-HART" },
      { "type" => "Player", "code" => "PLAYER-HART\n" }
    ].each { |record| refute schema.valid?(document.merge("records" => [record])) }
  end

  def test_registry_numeric_and_named_selections_with_inherited_family
    registry_document = { "05" => { "22" => %w[Sport Player] }, "terminology" => {
      "families" => { "athletes" => 5 }, "sequences" => { "05" => { "roster" => 22 } } } }
    registry = MICharismaSeeders::SequenceRegistry.new(registry_document)
    assert JSONSchemer.schema(exporter.documents.fetch("entity-sequences.schema.json")).valid?(registry_document)
    schema = JSONSchemer.schema(exporter.documents.fetch("manifest.schema.json"))
    ["05_22", [5, 22], ["athletes", "roster"]].each do |selection|
      value = document.merge("entity_sequence" => selection)
      assert schema.valid?(value)
      assert_equal "05_22", MICharismaSeeders::Reader.new(registry: registry).read_string(JSON.generate(value), format: :json).first.entity_sequence
    end
    value = document.merge("entity_sequence" => 5, "groups" => [{ "entity_sequence" => 22, "records" => [{ "type" => "Player", "code" => "PLAYER-HART" }] }])
    assert schema.valid?(value)
    assert_equal "05_22", MICharismaSeeders::Reader.new(registry: registry).read_string(JSON.generate(value), format: :json).first.entity_sequence
  end

  def test_runtime_entry_point_does_not_load_optional_schema_tooling
    output, status = Open3.capture2(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e",
      'require "micharisma_seeders"; abort "schema tool loaded" if defined?(Schematist)')
    assert status.success?, output
  end
end
