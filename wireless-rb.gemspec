# frozen_string_literal: true

require_relative "lib/wireless/version"

Gem::Specification.new do |spec|
  spec.name = "wireless-rb"
  spec.version = Wireless::VERSION
  spec.authors = [ "Gatework contributors" ]
  spec.summary = "Parse and collect wireless controller inventories."
  spec.description = "Wireless configuration, access point, radio, client and neighbor observations with independent command and nested-session failure handling."
  spec.homepage = "https://github.com/gatework/wireless-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.6"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}#readme",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  # 显式限定打包文件，排除设备回显、凭据、测试夹具和构建产物。
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "examples/**/*.rb", "lib/wireless/cli/templates/*", "bin/wireless", "bin/wireless.rb", "bin/README.md", "docs/**/*.md", "README*.md", "CHANGELOG.md", "LICENSE"].sort }
  spec.require_paths = [ "lib" ]
  spec.bindir = "bin"
  spec.executables = [ "wireless" ]

  spec.add_dependency "ctx_cli"
  spec.add_dependency "ctx_runner"
  spec.add_dependency "ctx_parser"
  spec.add_dependency "ctx_driver"
  spec.add_dependency "date"
  %w[time json optparse yaml fileutils tempfile ipaddr].each { |name| spec.add_dependency name }
end
