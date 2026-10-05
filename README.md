# MICharisma Seeders

Ruby standard-library tools for portable seed documents and readable entity-sequence lookups. This repository contains no Rails models, database writes, network fetching, or process-wide parser selection. An application adapter owns vocabulary resolution, dependency order, persistence, aliases, provenance ledgers, and preservation/conflict policy.

Use Ruby 3.1 or newer. Load directly with `ruby -Ilib`, or add this repository as a local gem:

```ruby
gem "micharisma_seeders", path: "lib/micharisma_seeders"
```

## Seed documents

JSON, YAML, and YML use the same `micharisma-seeds/v1` envelope:

```yaml
format: micharisma-seeds/v1
namespace: MIC
catalog: ALA
scope:
  Sport: BKT
  League: NBA
  Year: 2024
source:
  url: https://example.test/accepted-roster-capture
  captured_on: "2024-10-01"
entity_sequence: "01_10"
groups:
  - scope: {Team: BOS}
    records:
      - type: Team
        code: BKT-NBA-BOS
        attributes: {mascot: Celtics}
        references:
          league: BKT-NBA
  - scope: {Team: NYK}
    records:
      - type: Team
        code: BKT-NBA-NYK
        attributes: {mascot: Knicks}
        references:
          league: {code: NBA, entity_sequence: "01_20", scope: {Sport: BKT}}
```

The URL above illustrates source metadata; the library never fetches it. Example sequence selections require matching entries in the caller's registry. Issued record codes are stable identity keys, independent of the selected lookup sequence; a selected sequence does **not** cause the Reader to reinterpret or rewrite record codes.

Header fields: `format`, `namespace`, `catalog`, optional `scope`, `source`, `entity_sequence`, `records`, and `groups`. Groups permit `scope`, `source`, `entity_sequence`, `records`, and recursively nested `groups`. Records require `type` and `code`, and permit `aliases`, `attributes`, `references`, `scope`, `entity_sequence`, and `source`. Unknown envelope/group/record fields fail with the file and document location. The application adapter validates its allowed types and model attributes.

Scopes merge from file → ancestor groups → nearest group → record. Keys normalize `Sport`/`sport` to `sport`, and `AtBat`/`at_bat` to `at_bat`. Values must be nonblank strings or integers; integer years become strings. Entity names are data, never evaluated as Ruby constants. An explicit null scope or scope value is invalid. `source` mappings merge shallowly with nearer keys overriding inherited keys. `entity_sequence` inherits and may be overridden at group or record level; null selections are invalid. Each file starts with empty context.

References are exact code strings or mappings containing required `code` and optional `entity_sequence`, `scope`, `namespace`, and `catalog`. Reference scopes remain explicit overrides: the application combines them with the record scope when performing a selected lookup. References without a selected sequence are for the application's exact code/alias resolver. Arrays, numeric database IDs, and extra reference-object fields are rejected.

```ruby
require "micharisma_seeders"

reader = MICharismaSeeders::Reader.new
records = reader.read("accepted.yaml")
# Also available: reader.read_string(text, format: :json, path: "capture.json")
# and reader.read_many(["directory", "another.json"]).

record = records.first
record.type             # declared type spelling
record.code             # issued key, unchanged
record.aliases          # [] unless supplied
record.attributes       # model fields, {} unless supplied
record.references       # {} unless supplied
record.scope            # fully inherited, normalized string-key mapping
record.namespace        # "MIC"
record.catalog          # "ALA"
record.source           # inherited mapping, or nil
record.entity_sequence  # normalized sequence ID, or nil
record.location         # file plus document pointer
record.to_h             # same fields with symbol keys
```

Records and all nested contents are frozen. Discovery is sorted; row order is preserved, with a container's records preceding its child groups. File paths/extensions control discovery, parsing, and diagnostics only. Relocating a file changes its diagnostic location; it cannot change entity identity, scope, type, or retrieval behavior.

## Two-level entity-sequence registry

Registry files contain the mapping directly:

```yaml
01:
  10: [Sport, League, Conference, Division, Year, Team]
  11: [Team, Year, Sport, League]
```

Unquoted numeric and quoted decimal family/member keys are accepted and normalize to strings such as `01_10`. Each part is 0–99. Normalization collisions such as `01` and `"01"` fail. Slots normalize like scope keys and must be nonempty and distinct; use explicit semantic names for different roles, such as `home_team` and `away_team`. The registry is immutable.

```ruby
registry = MICharismaSeeders::SequenceRegistry.read("sequences.yaml")
# Or: SequenceRegistry.new({"01" => {"10" => %w[Sport League Year Team]}})
registry.fetch("01_10").slots # normalized entity names

parser = MICharismaEntityParser.select_entity_sequence(
  "01_11", registry: registry, namespace: "MIC", catalog: "ALA"
)
parser.resolve("NYK-2024-BKT-NBA")
# => {"team"=>"NYK", "year"=>"2024", "sport"=>"BKT", "league"=>"NBA"}

parser.resolve("NYK", scope: {Sport: "BKT", League: "NBA", Year: 2024})
# => the same mapping; Year can occur anywhere in the selected recipe.
```

`MICharismaEntityParser` aliases `MICharismaSeeders::MICharismaEntityParser`. Selection returns an independent frozen parser. Sequence IDs supplied in Ruby/records are **strings**, such as `"01_10"`; bare `01_10` is a Ruby octal literal. Unknown IDs, including undefined `00_00`, fail rather than selecting a guessed recipe.

Fully supplied codes map positionally, with their explicit values taking precedence over defaults in scope. `MIC-ALA-...` qualification is removed only after namespace/catalog validation. Shorter codes are ordered subsequences: missing slots must be filled by known scope values, and an explicitly supplied scoped slot must match its known value. A scope value may be a whole canonical entity reference containing dashes, such as `SPORT-BKT`, `BKT-LEAGUE-NBA`, or `YEAR-2022`; that known reference is retained intact as one slot's value and is never split. For example, `resolve("POR", scope: {Sport: "SPORT-BKT", League: "BKT-LEAGUE-NBA", Year: "YEAR-2022"})` under `[Sport, League, Year, Team]` returns those three complete references plus `"team" => "POR"`. Multiple possible mappings raise `AmbiguousCodeError`. Blank components, unsupported characters, excess components, and insufficient scope fail. Values remain vocabulary tokens or explicit references; the application must resolve and validate them. No literal `TEAM` or `SEASON` markers are injected.

Provide an adapter to return application entities instead of the parsed mapping:

```ruby
class CatalogAdapter
  def resolve_sequence(mapping)
    # Resolve vocabulary, check scope/type consistency, then return a result.
    # Never constantize names from mapping/input. Raise on ambiguous targets.
  end
end

parser = MICharismaEntityParser.select_entity_sequence(
  "01_11", registry: registry, catalog: "ALA", adapter: CatalogAdapter.new
)
parser.resolve("NYK-2024-BKT-NBA") # returns adapter.resolve_sequence(mapping)
```

The adapter receives a frozen string-key mapping only. It owns supported resolver names and required relationship checks. It may raise application-specific unresolved-reference errors for a dependency-aware runner to retry. The core supplies no database ordering or importer write policy.

For a small Ruby DSL, create a **new context for each file**:

```ruby
context = MICharismaSeeders::Context.new(registry: registry, catalog: "ALA")
context.sequence_is "01_11" # lasts within this context only
context.sequence_is("01_10") do |local|
  local.resolve("BKT-NBA-EAST-ATLANTIC-2024-NYK")
end # prior selection restored, even after an exception
```

A context is caller-local and mutable; use separate contexts for concurrent callers. Parser instances and registry/record data are immutable.

## Validation and safety

```sh
ruby exe/micharisma-seeds validate --registry sequences.yaml accepted-seeds/
ruby -Ilib test/core_test.rb
```

The CLI validates document structure and, when a registry is supplied, selected sequence IDs. It performs no network requests or data writes and does not claim to validate model fields, factual accuracy, identity collisions across files, or reference existence. The explicitly supplied registry file is excluded from seed discovery.

Both parsers reject duplicate mapping keys. YAML also rejects aliases, merge keys, custom/Ruby tags, multiple documents, and non-finite numbers. Standard YAML dates/timestamps become ISO strings. JSON additions are disabled. ERB is rejected and never evaluated. Parse/validation failures raise subclasses of `MICharismaSeeders::Error`: `ParseError`, `ValidationError`, `DuplicateKeyError`, `UnknownSequenceError`, `CodeError`, and `AmbiguousCodeError`; errors expose `location` when available.
