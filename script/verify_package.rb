# frozen_string_literal: true

require "rubygems/package"
require "tmpdir"
require "rbconfig"

# 仅验证发布文件与解析后的依赖，避免从工作区加载代码。
artifact = File.expand_path(ARGV.fetch(0))
spec = Gem::Package.new(artifact).spec
abort "Unexpected package" unless spec.name == "wireless-rb"
abort "Transport must be optional" if spec.runtime_dependencies.any? { |dependency| dependency.name == "net-connector" }
abort "Unexpected package contents" if spec.files.any? { |path| path.start_with?("spec/", "test/", "storage/", "tmp/") || path.end_with?(".log", ".gem") }
Dir.mktmpdir("gem-install-") do |home|
  env = ENV.to_h.keys.grep(/\A(?:BUNDLE_|RUBY)/).to_h { |key| [ key, nil ] }
  env.merge!("GEM_HOME" => home, "GEM_PATH" => home, "RUBYOPT" => nil, "RUBYLIB" => nil)
  ruby = RbConfig.ruby
  system(env, ruby, "-S", "gem", "install", artifact, "--no-document", exception: true)
  check = <<~RUBY
    require "wireless"
    abort "Unexpected Rails dependency" if defined?(Rails)
    abort "Unexpected transport dependency" if defined?(Net::Connector) || Gem::Specification.find_all_by_name("net-connector").any?
    configuration = Wireless::Configuration.new.parse("sysname WLC\\nreturn\\n", complete: true)
    abort "Offline configuration parsing failed" unless configuration.complete?
    huawei = Wireless::RuntimeParser.new.parse(:access_points, "ID MAC Name Group IP Type State STA Uptime\\nTotal: 0\\n", platform: :huawei, complete: true)
    abort "Installed Huawei profile failed" unless huawei.complete? && huawei.records.empty?
    begin
      Wireless::RuntimeParser.new.parse(:access_points, "", platform: :huawei, complete: "false")
      abort "Invalid completeness accepted"
    rescue ArgumentError
    end
    loaded = Gem.loaded_specs.fetch("wireless-rb")
    abort "Loaded checkout instead of package" unless File.realpath(loaded.full_gem_path).start_with?(File.realpath(ENV.fetch("GEM_HOME")) + "/")
    abort "Version mismatch" unless loaded.version.to_s == #{spec.version.to_s.inspect}
    Dir[File.join(loaded.full_gem_path, "examples/**/*.rb")].sort.each { |path| load path }
  RUBY
  system(env, ruby, "-e", check, chdir: home, exception: true)
end
