# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../lib/micharisma_seeders"

class CoreTest < Minitest::Test
  class JSONAdditionProbe
    def self.json_create(_data)
      raise "JSON additions must never execute"
    end
  end

  def reader
    MICharismaSeeders::Reader.new
  end

  def document
    { "format" => "micharisma-seeds/v1", "namespace" => "MIC", "catalog" => "ALA",
      "scope" => { "Sport" => "BKT", "League" => "NBA", "Year" => 2024 },
      "source" => { "url" => "https://example.test/roster", "captured_on" => "2024-10-01" },
      "entity_sequence" => "01_10",
      "groups" => [
        { "scope" => { "Team" => "BOS" },
          "records" => [{ "type" => "Player", "code" => "TATUM_JAYSON",
                           "attributes" => { "first_name" => "Jayson" },
                           "references" => { "team" => { "code" => "BOS", "entity_sequence" => "01_10" } } }],
          "groups" => [{ "scope" => { "team" => "NYK" }, "source" => { "url" => "https://example.test/knicks" },
                         "records" => [{ "type" => "Player", "code" => "BRUNSON_JALEN", "scope" => { "Year" => 2025 } }] }] },
        { "scope" => { "Team" => "DEN" }, "records" => [{ "type" => "Team", "code" => "NUGGETS" }] }
      ] }
  end

  def registry
    MICharismaSeeders::SequenceRegistry.new({ "01" => { "10" => %w[Sport League Year Team], "11" => %w[Team Year Sport League] } })
  end

  def parser(id = "01_10", **options)
    MICharismaSeeders::MICharismaEntityParser.select_entity_sequence(id, registry: registry, catalog: "ALA", **options)
  end

  def terminology_registry
    MICharismaSeeders::SequenceRegistry.new({
      "01" => { "10" => %w[Sport League Year Team], "11" => %w[Team Year Sport League] },
      "05" => { "22" => %w[Sport League Team Year Player], "23" => %w[Sport Player] },
      "terminology" => {
        "families" => { "teams" => 1, "athletes" => 5 },
        "sequences" => {
          "01" => { "roster" => 10, "reordered" => 11 },
          "05" => { "roster" => 22, "person" => 23 }
        }
      }
    })
  end

  def test_string_integer_pair_and_staged_selection_have_the_same_recipe
    selected = MICharismaEntityParser.select_entity_sequence("05_22", registry: terminology_registry)
    pair = MICharismaEntityParser.select_entity_sequence(5, 22, registry: terminology_registry)
    pending = MICharismaEntityParser.select_entity_sequence(5, registry: terminology_registry)
    assert_nil pending.sequence
    assert_equal "05", pending.sequence_family
    assert_raises(MICharismaSeeders::UnknownSequenceError) { pending.resolve("HART_JOSH") }
    staged = pending.select_entity_sequence(22)
    [selected, pair, staged].each do |configured|
      assert_equal "05_22", configured.sequence.id
      assert_equal "HART_JOSH", configured.resolve("BKT-NBA-NYK-2022-HART_JOSH")["player"]
    end
    assert_nil pending.sequence
    assert_equal "05_23", staged.select_entity_sequence(23).sequence.id
    assert_nil staged.select_entity_sequence_family(1).sequence
    assert_equal "01_10", staged.select_entity_sequence_family(1).select_entity_sequence(10).sequence.id
    assert_equal "05_22", terminology_registry.fetch(5, 22).id
  end

  def test_terminology_names_mixed_with_numbers_and_scoped_to_their_family
    configured = MICharismaEntityParser.select_entity_sequence(:athletes, :roster, registry: terminology_registry)
    assert_equal "05_22", configured.sequence.id
    assert_equal "01_10", terminology_registry.fetch(:teams, :roster).id
    assert_equal "05_22", terminology_registry.fetch(5, "roster").id
    assert_equal "05_22", terminology_registry.fetch("Athletes", 22).id
    pending = MICharismaEntityParser.select_entity_sequence(:athletes, registry: terminology_registry)
    assert_equal "05_22", pending.select_entity_sequence(:roster).sequence.id
    assert_equal "01_11", configured.select_entity_sequence_family(:teams).select_entity_sequence(:reordered).sequence.id
    assert_raises(MICharismaSeeders::UnknownSequenceError) { configured.select_entity_sequence(:reordered) }
  end

  def test_staged_seed_helper_blocks_restore_family_and_member_and_failed_choices_are_atomic
    context = MICharismaSeeders::Context.new(registry: terminology_registry)
    context.sequence_is 5
    context.sequence_is 22
    assert_equal "05_22", context.parser.sequence.id
    previous = context.parser
    assert_raises(MICharismaSeeders::UnknownSequenceError) { context.sequence_is 99 }
    assert_same previous, context.parser
    assert_raises(RuntimeError) do
      context.sequence_family_is(:teams) do |local|
        assert_nil local.parser.sequence
        local.sequence_is :roster
        assert_equal "01_10", local.parser.sequence.id
        raise "stop"
      end
    end
    assert_same previous, context.parser
    context.sequence_is(:teams, :roster) do |local|
      assert_equal "01_10", local.parser.sequence.id
    end
    assert_same previous, context.parser
    assert_nil MICharismaSeeders::Context.new(registry: terminology_registry).parser.sequence_family
  end

  def test_invalid_numeric_choices_never_guess_combined_ids
    [522, 338, -1, 100, 5.0, nil].each do |value|
      assert_raises(MICharismaSeeders::ValidationError) { MICharismaEntityParser.select_entity_sequence(value, registry: terminology_registry) }
    end
    assert_raises(MICharismaSeeders::UnknownSequenceError) { MICharismaEntityParser.select_entity_sequence(9, registry: terminology_registry) }
    assert_raises(MICharismaSeeders::ValidationError) { terminology_registry.fetch(5, 100) }
    assert_raises(MICharismaSeeders::ValidationError) { terminology_registry.fetch(5, 22, 1) }
  end

  def test_terminology_rejects_unknown_targets_and_normalized_name_collisions
    base = { "05" => { "22" => %w[Player] } }
    terms = { "families" => { "Athletes" => 5, "athletes" => 5 } }
    assert_raises(MICharismaSeeders::DuplicateKeyError) { MICharismaSeeders::SequenceRegistry.new(base.merge("terminology" => terms)) }
    terms = { "families" => { "athletes" => 6 } }
    assert_raises(MICharismaSeeders::UnknownSequenceError) { MICharismaSeeders::SequenceRegistry.new(base.merge("terminology" => terms)) }
    terms = { "sequences" => { "05" => { "roster" => 23 } } }
    assert_raises(MICharismaSeeders::UnknownSequenceError) { MICharismaSeeders::SequenceRegistry.new(base.merge("terminology" => terms)) }
  end

  def test_yaml_and_json_numeric_pairs_staged_names_and_reference_member_choices
    input = document
    input["entity_sequence"] = "athletes"
    input["groups"] = [
      { "entity_sequence" => "roster", "records" => [{ "type" => "Player", "code" => "HART_JOSH", "references" => {
        "team" => { "code" => "NYK", "entity_sequence" => ["teams", "roster"] },
        "player" => { "code" => "HART_JOSH", "entity_sequence" => 23 }
      } }] },
      { "entity_sequence" => 23, "records" => [{ "type" => "Player", "code" => "LEDDY_NICK" }] },
      { "entity_sequence" => [1, 10], "groups" => [{ "entity_sequence" => 11,
        "records" => [{ "type" => "Team", "code" => "KNICKS" }] }] }
    ]
    configured_reader = MICharismaSeeders::Reader.new(registry: terminology_registry)
    json = configured_reader.read_string(JSON.generate(input), format: :json)
    yaml = configured_reader.read_string(Psych.dump(input), format: :yaml)
    assert_equal json.map(&:to_h), yaml.map(&:to_h)
    assert_equal %w[05_22 05_23 01_11], yaml.map(&:entity_sequence)
    assert_equal "01_10", yaml.first.references["team"]["entity_sequence"]
    assert_equal "05_23", yaml.first.references["player"]["entity_sequence"]
    assert_raises(MICharismaSeeders::ValidationError) { reader.read_string(Psych.dump(input), format: :yaml) }
    next_file = document.merge("entity_sequence" => 22)
    assert_raises(MICharismaSeeders::ValidationError) { configured_reader.read_string(Psych.dump(next_file), format: :yaml) }
  end

  def test_named_and_numeric_yaml_terminology_resolves_to_the_same_registry
    text = Psych.dump({ "05" => { "22" => %w[Player] }, "terminology" => {
      "families" => { "athletes" => 5 }, "sequences" => { "05" => { "roster" => 22 } }
    } })
    config = MICharismaSeeders::SequenceRegistry.new(MICharismaSeeders::SafeDocument.parse(text, format: :yaml))
    assert_equal config.fetch("05_22"), config.fetch(:athletes, :roster)
  end

  def test_micharisma_parser_entry_point_and_filename
    library_path = File.expand_path("../lib", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{library_path}", "-e", 'require "micharisma_entity_parser"; puts MICharismaEntityParser.name')
    assert status.success?, stderr
    assert_equal "MICharismaSeeders::MICharismaEntityParser\n", stdout
    assert_equal "micharisma_entity_parser.rb", File.basename(MICharismaEntityParser.method(:select_entity_sequence).source_location.first)
  end

  def test_json_yaml_parity_and_nested_mixed_team_scope
    json = reader.read_string(JSON.generate(document), format: :json)
    yaml = reader.read_string(Psych.dump(document), format: :yaml)
    assert_equal json.map(&:to_h), yaml.map(&:to_h)
    assert_equal %w[BOS NYK DEN], yaml.map { |record| record.scope["team"] }
    assert_equal %w[2024 2025 2024], yaml.map { |record| record.scope["year"] }
    assert_equal "https://example.test/knicks", yaml[1].source["url"]
    assert_equal "2024-10-01", yaml[1].source["captured_on"]
    assert_equal "01_10", yaml[0].entity_sequence
  end

  def test_group_and_record_sequence_override_do_not_bleed
    input = document
    input["groups"][0]["entity_sequence"] = "01_11"
    input["groups"][0]["records"][0]["entity_sequence"] = "02_01"
    records = reader.read_string(JSON.generate(input), format: :json)
    assert_equal %w[02_01 01_11 01_10], records.map(&:entity_sequence)
    next_file = { "format" => "micharisma-seeds/v1", "namespace" => "MIC", "catalog" => "ASC",
                  "records" => [{ "type" => "Goal", "code" => "PRACTICE" }] }
    record = reader.read_string(JSON.generate(next_file), format: :json).first
    assert_equal({}, record.scope)
    assert_nil record.source
    assert_nil record.entity_sequence
  end

  def test_records_are_deeply_immutable
    row = reader.read_string(JSON.generate(document), format: :json).first
    assert row.frozen?
    assert_raises(FrozenError) { row.scope["team"] = "NYK" }
    assert_raises(FrozenError) { row.attributes["first_name"].replace("Other") }
    assert_raises(FrozenError) { row.references["team"]["code"].replace("DEN") }
  end

  def test_filename_relocation_does_not_change_identity_or_scopes
    Dir.mktmpdir do |directory|
      first = File.join(directory, "basketball", "nba.json")
      second = File.join(directory, "misc", "moved.yaml")
      FileUtils.mkdir_p(File.dirname(first))
      FileUtils.mkdir_p(File.dirname(second))
      File.write(first, JSON.generate(document))
      File.write(second, Psych.dump(document))
      left = reader.read(first).map { |row| row.to_h.reject { |name, _| name == :location } }
      right = reader.read(second).map { |row| row.to_h.reject { |name, _| name == :location } }
      assert_equal left, right
      assert_equal [first, second].sort, MICharismaSeeders::Reader.discover(directory)
    end
  end

  def test_numeric_yaml_registry_keys_and_leading_zeroes
    registry = MICharismaSeeders::SequenceRegistry.new(MICharismaSeeders::SafeDocument.parse("01: {10: [Sport, League, Conference, Division, Year, Team]}\n", format: :yaml))
    assert_equal "01_10", registry.fetch("01_10").id
    assert_equal %w[sport league conference division year team], registry.fetch("01_10").slots
    assert_equal "01_01", MICharismaSeeders::SequenceRegistry.normalize_id("1_1")
    assert_raises(MICharismaSeeders::ValidationError) { registry.fetch(110) }
  end

  def test_normalized_registry_duplicates_are_rejected
    ["01: {10: [Team]}\n\"01\": {11: [Year]}\n", "01: {10: [Team], \"10\": [Year]}\n"].each do |yaml|
      data = MICharismaSeeders::SafeDocument.parse(yaml, format: :yaml)
      assert_raises(MICharismaSeeders::DuplicateKeyError) { MICharismaSeeders::SequenceRegistry.new(data) }
    end
  end

  def test_unknown_sequence_and_reserved_number_are_not_inferred
    assert_raises(MICharismaSeeders::UnknownSequenceError) { parser("99_99") }
    assert_raises(MICharismaSeeders::UnknownSequenceError) { parser("00_00") }
    unselected = MICharismaSeeders::MICharismaEntityParser.new(registry: registry)
    assert_raises(MICharismaSeeders::UnknownSequenceError) { unselected.resolve("BKT") }
  end

  def test_full_and_qualified_codes_and_year_in_any_position
    expected = { "sport" => "BKT", "league" => "NBA", "year" => "2024", "team" => "NYK" }
    assert_equal expected, parser.resolve("BKT-NBA-2024-NYK")
    assert_equal expected, parser.resolve("MIC-ALA-BKT-NBA-2024-NYK")
    assert_equal expected, parser("01_11").resolve("NYK-2024-BKT-NBA")
    assert_same MICharismaSeeders::MICharismaEntityParser, ::MICharismaEntityParser
  end

  def test_short_codes_fill_known_scope_without_assuming_year_position
    scope = { "Sport" => "BKT", "League" => "NBA", "Year" => 2024 }
    expected = { "sport" => "BKT", "league" => "NBA", "year" => "2024", "team" => "NYK" }
    assert_equal expected, parser.resolve("NYK", scope: scope)
    assert_equal expected, parser.resolve("NBA-NYK", scope: scope)
    assert_equal expected, parser("01_11").resolve("NYK", scope: scope)
    assert_raises(MICharismaSeeders::CodeError) { parser.resolve("NYK", scope: { "Sport" => "BKT" }) }
  end

  def test_short_codes_preserve_whole_scoped_entity_references_as_single_values
    scope = { "Sport" => "SPORT-BKT", "League" => "BKT-LEAGUE-NBA", "Year" => "YEAR-2022" }
    expected = { "sport" => "SPORT-BKT", "league" => "BKT-LEAGUE-NBA", "year" => "YEAR-2022", "team" => "POR" }
    assert_equal expected, parser.resolve("POR", scope: scope)
    assert_equal expected, parser("01_11").resolve("POR", scope: scope)
    assert_equal "BKT", parser.resolve("BKT-NBA-2022-POR", scope: scope)["sport"]
  end

  def test_invalid_component_lengths_blank_components_and_wrong_catalog
    %w[BKT-NBA-2024-NYK-EXTRA BKT--2024-NYK -BKT-NBA-2024-NYK BKT-NBA-2024-NYK- MIC-SPD-BKT-NBA-2024-NYK].each do |code|
      assert_raises(MICharismaSeeders::CodeError) { parser.resolve(code) }
    end
  end

  def test_ambiguous_short_code_does_not_guess
    custom = MICharismaSeeders::SequenceRegistry.new({ "01" => { "12" => %w[Sport League Team] } })
    selected = ::MICharismaEntityParser.select_entity_sequence("01_12", registry: custom)
    assert_raises(MICharismaSeeders::AmbiguousCodeError) do
      selected.resolve("BKT-NBA", scope: { "sport" => "BKT", "team" => "NBA" })
    end
  end

  def test_adapter_interface_receives_mapping_without_model_evaluation
    adapter = Object.new
    def adapter.resolve_sequence(mapping)
      [:resolved, mapping]
    end
    result = parser(adapter: adapter).resolve("BKT-NBA-2024-NYK")
    assert_equal :resolved, result.first
    assert_equal "NYK", result.last["team"]
    assert result.last.frozen?
  end

  def test_parser_selection_is_independent_and_context_block_restores_on_error
    original = parser
    changed = original.select_entity_sequence("01_11")
    assert_equal "01_10", original.sequence.id
    assert_equal "01_11", changed.sequence.id
    context = MICharismaSeeders::Context.new(registry: registry, catalog: "ALA")
    context.sequence_is("01_10")
    assert_raises(RuntimeError) do
      context.sequence_is("01_11") do |local|
        assert_equal "01_11", local.parser.sequence.id
        raise "stop"
      end
    end
    assert_equal "01_10", context.parser.sequence.id
    fresh = MICharismaSeeders::Context.new(registry: registry, catalog: "ALA")
    assert_nil fresh.parser.sequence
  end

  def test_duplicate_keys_are_rejected_in_json_and_yaml_with_location
    [[:json, '{"outer":{"x":1,"x":2}}'], [:yaml, "outer:\n  x: 1\n  x: 2\n"]].each do |format, text|
      error = assert_raises(MICharismaSeeders::DuplicateKeyError) { reader.read_string(text, format: format, path: "duplicate.#{format}") }
      assert_includes error.message, "duplicate.#{format}"
    end
  end

  def test_json_duplicates_are_rejected_before_native_hash_conversion
    samples = [
      '{"x":null,"x":1}',
      '{"records":[{"attributes":{"name":"first","name":"second"}}]}',
      '{"x":1,"\u0078":2}'
    ]
    samples.each do |text|
      error = assert_raises(MICharismaSeeders::DuplicateKeyError) do
        MICharismaSeeders::SafeDocument.parse(text, format: :json, path: "duplicate.json")
      end
      assert_includes error.message, "duplicate.json"
    end
    value = MICharismaSeeders::SafeDocument.parse('{"outer":[{"name":"valid"}],"empty":{}}', format: :json)
    assert_instance_of Hash, value
    assert_instance_of Hash, value["outer"].first
    assert_instance_of Hash, value["empty"]
  end

  def test_normalized_scope_duplicates_unknown_fields_and_invalid_reference
    input = document
    input["scope"]["sport"] = "SOC"
    assert_raises(MICharismaSeeders::DuplicateKeyError) { reader.read_string(JSON.generate(input), format: :json) }
    input = document
    input["groups"][0]["records"][0]["unknown"] = true
    error = assert_raises(MICharismaSeeders::ValidationError) { reader.read_string(JSON.generate(input), format: :json, path: "seed.json") }
    assert_includes error.message, "seed.json:$.groups[0].records[0]"
    input = document
    input["groups"][0]["records"][0]["references"]["team"] = 1
    assert_raises(MICharismaSeeders::ValidationError) { reader.read_string(JSON.generate(input), format: :json) }
  end

  def test_rejects_yaml_objects_aliases_erb_and_multiple_documents
    ["--- !ruby/object:Object {}\n", "x: &value {}\ny: *value\n", "--- {}\n--- {}\n", "value: <%= system('anything') %>\n"].each do |text|
      assert_raises(MICharismaSeeders::ParseError) { reader.read_string(text, format: :yaml) }
    end
  end

  def test_standard_yaml_dates_are_portable_and_json_additions_do_not_execute
    value = MICharismaSeeders::SafeDocument.parse("captured_on: 2024-10-01\n", format: :yaml)
    assert_equal "2024-10-01", value["captured_on"]
    value = MICharismaSeeders::SafeDocument.parse('{"json_class":"Object","value":1}', format: :json)
    assert_equal "Object", value["json_class"]
    value = MICharismaSeeders::SafeDocument.parse('{"json_class":"CoreTest::JSONAdditionProbe","value":1}', format: :json)
    assert_instance_of Hash, value
    assert_equal "CoreTest::JSONAdditionProbe", value["json_class"]
  end

  def test_cli_validates_without_writing_and_reports_unknown_sequences
    Dir.mktmpdir do |directory|
      seed_path = File.join(directory, "anything.json")
      registry_path = File.join(directory, "sequences.yaml")
      File.write(seed_path, JSON.generate(document))
      File.write(registry_path, Psych.dump({ "01" => { "10" => %w[Sport League Year Team] } }))
      before = File.binread(seed_path)
      executable = File.expand_path("../exe/micharisma-seeds", __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, executable, "validate", "--registry", registry_path, directory)
      assert status.success?, stderr
      assert_includes stdout, "Validated 3 records in 1 documents"
      assert_equal before, File.binread(seed_path)
      named = document.merge("entity_sequence" => ["teams", "roster"])
      named["groups"][0]["records"][0]["references"]["team"]["entity_sequence"] = "roster"
      File.write(seed_path, Psych.dump(named))
      File.rename(seed_path, seed_path = File.join(directory, "anything.yaml"))
      File.write(registry_path, Psych.dump({ "01" => { "10" => %w[Sport League Year Team] }, "terminology" => {
        "families" => { "teams" => 1 }, "sequences" => { "01" => { "roster" => 10 } }
      } }))
      before = File.binread(seed_path)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, executable, "validate", "--registry", registry_path, directory)
      assert status.success?, stderr
      assert_includes stdout, "Validated 3 records in 1 documents"
      assert_equal before, File.binread(seed_path)
      input = document
      input["entity_sequence"] = "99_99"
      File.write(seed_path, Psych.dump(input))
      _, stderr, status = Open3.capture3(RbConfig.ruby, executable, "validate", "--registry", registry_path, seed_path)
      refute status.success?
      assert_includes stderr, "unknown entity sequence"
    end
  end
end
