# frozen_string_literal: true

require_relative "lib/corvid/version"

Gem::Specification.new do |spec|
  spec.name        = "corvid"
  spec.version     = Corvid::VERSION
  spec.authors     = ["Lakeraven"]
  spec.email       = ["eng@lakeraven.com"]
  spec.homepage    = "https://github.com/lakeraven/corvid"
  spec.summary     = "Case management engine for healthcare, social services, and benefit programs"
  spec.description = "EHR-agnostic Rails engine for managing service authorization workflows, " \
                     "referral tracking, eligibility verification, and budget obligations. " \
                     "PHI-tokenized at rest. Works with any FHIR R4 server via pluggable adapters."
  spec.license     = "MIT"
  spec.metadata    = {
    "homepage_uri"      => "https://github.com/lakeraven/corvid",
    "source_code_uri"   => "https://github.com/lakeraven/corvid",
    "changelog_uri"     => "https://github.com/lakeraven/corvid/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/lakeraven/corvid/tree/main/docs"
  }

  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", "~> 8.1"
  spec.add_dependency "aasm", "~> 5.5"
  spec.add_dependency "pg", "~> 1.5"
  spec.add_dependency "ulid", "~> 1.4"
end
