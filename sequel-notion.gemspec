# frozen_string_literal: true

require_relative "lib/sequel-notion/version"

Gem::Specification.new do |s|
  s.name        = "sequel-notion"
  s.version     = SequelNotion::VERSION
  s.authors     = ["Stéphane D'Alu"]
  s.email       = ["sdalu@sdalu.com"]

  s.summary     = "Sequel adapter for Notion data sources"
  s.description = "A Sequel database adapter that maps Notion databases " \
                  "and data sources to Sequel's Dataset interface. " \
                  "Supports multi-source databases, filtering, sorting, " \
                  "pagination, and CRUD operations via the Notion API (2026-03-11)."
  s.homepage    = "https://github.com/sdalu/sequel-notion"
  s.license     = "MIT"

  s.required_ruby_version = ">= 3.1"

  s.metadata = {
    "homepage_uri"          => s.homepage,
    "source_code_uri"       => s.homepage,
    "changelog_uri"         => "#{s.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
  }

  s.files = Dir.chdir(__dir__) do
    Dir["{lib}/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
      .reject { |f| File.directory?(f) }
  end

  s.require_paths = ["lib"]

  # Runtime
  s.add_dependency "sequel",       "~> 5.0"
  s.add_dependency "faraday",      "~> 2.0"
  s.add_dependency "faraday-retry", "~> 2.0"
end
