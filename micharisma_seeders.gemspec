# frozen_string_literal: true

require_relative "lib/micharisma_seeders"

Gem::Specification.new do |spec|
  spec.name = "micharisma_seeders"
  spec.version = MICharismaSeeders::VERSION
  spec.summary = "Portable scoped seed documents and readable entity-sequence parsing"
  spec.authors = ["MICharisma Inc"]
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["micharisma-seeds"]
  spec.require_paths = ["lib"]
end
