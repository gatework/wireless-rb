# frozen_string_literal: true

require "rubygems/package"
require "tmpdir"
require "rbconfig"
require "fileutils"

# 仅验证发布文件与解析后的依赖，避免从工作区加载代码。
artifact = File.expand_path(ARGV.fetch(0))
connector_artifact = ARGV[1] && File.expand_path(ARGV[1])
expect_artifact = ARGV[2] && File.expand_path(ARGV[2])
runner_artifact = ARGV[3] && File.expand_path(ARGV[3])
cli_artifact = ARGV[4] && File.expand_path(ARGV[4])
parser_dependencies = ARGV.drop(5).map { |path| File.expand_path(path) }
parser_dependencies.each do |path|
  abort "Unexpected parsing dependency" unless %w[ctx_parser ctx_driver].include?(Gem::Package.new(path).spec.name)
end
cli_spec = cli_artifact && Gem::Package.new(cli_artifact).spec
abort "Unexpected CLI candidate" if cli_spec && cli_spec.name != "ctx_cli"
runner_spec = runner_artifact && Gem::Package.new(runner_artifact).spec
abort "Unexpected runner candidate" if runner_spec && runner_spec.name != "ctx_runner"
spec = Gem::Package.new(artifact).spec
abort "Unexpected package" unless spec.name == "wireless-rb"
abort "Missing CLI guide" unless spec.files.include?("bin/README.md")
abort "Local bin configuration packaged" if spec.files.any? { |path| path.start_with?("bin/") && !%w[bin/wireless bin/wireless.rb bin/README.md].include?(path) }
abort "Legacy implementation packaged" if spec.files.any? { |path| path.start_with?("examples/support/") }
abort "Unexpected package contents" if spec.files.any? { |path| path.start_with?("spec/", "test/", "storage/", "tmp/") || path.end_with?(".log", ".gem") }
# 本地开发包只使用已安装依赖的缓存，避免重新求解远端依赖或借用开发加载路径。
local_dependencies = []
if connector_artifact
  pending = Gem::Package.new(connector_artifact).spec.runtime_dependencies.dup
  seen = []
  until pending.empty?
    dependency = pending.shift
    next if seen.include?(dependency.name)
    seen << dependency.name
    selected = if dependency.name == "ctx_cli" && cli_spec
      cli_spec
    elsif dependency.name == "expect-pty" && expect_artifact
      Gem::Package.new(expect_artifact).spec
    else
      Gem::Specification.find_all_by_name(dependency.name, dependency.requirement).max_by(&:version)
    end
    abort "Missing local dependency: #{dependency.name}" unless selected && dependency.matches_spec?(selected)
    cache = if dependency.name == "ctx_cli" && cli_artifact
      cli_artifact
    elsif dependency.name == "expect-pty" && expect_artifact
      expect_artifact
    else
      selected.cache_file
    end
    if File.file?(cache)
      local_dependencies << cache
    elsif !selected.default_gem?
      abort "Missing dependency cache: #{dependency.name}"
    end
    pending.concat(selected.runtime_dependencies)
  end
end

Dir.mktmpdir("gem-install-") do |home|
  env = ENV.to_h.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBY|WIRELESS_|NC_|ND_)/).to_h { |key| [ key, nil ] }
  env.merge!("GEM_HOME" => home, "GEM_PATH" => home, "RUBYOPT" => nil, "RUBYLIB" => nil, "HOME" => File.join(home, "user"), "XDG_CONFIG_HOME" => File.join(home, "config"))
  local_dependencies.each { |path| FileUtils.cp(path, home) }
  ruby = RbConfig.ruby
  system(env, ruby, "-S", "gem", "install", cli_artifact, "--no-document", exception: true) if cli_artifact
  parser_dependencies.each { |path| system(env, ruby, "-S", "gem", "install", path, "--no-document", exception: true) }
  system(env, ruby, "-S", "gem", "install", runner_artifact, "--no-document", exception: true) if runner_artifact
  system(env, ruby, "-S", "gem", "install", artifact, "--no-document", exception: true)
  if cli_artifact
    installed = File.join(home, "gems", cli_spec.full_name)
    Dir.mktmpdir("cli-candidate-") do |source|
      Gem::Package.new(cli_artifact).extract_files(source)
      cli_spec.files.each do |path|
        abort "CLI candidate byte mismatch: #{path}" unless File.binread(File.join(source, path)) == File.binread(File.join(installed, path))
      end
    end
  end
  activation = runner_spec ? "gem #{runner_spec.name.inspect}, #{"= #{runner_spec.version}".inspect}" : ""
  check = <<~RUBY
    #{activation}
    require "wireless"
    require "rbconfig"
    abort "Unexpected Rails dependency" if defined?(Rails)
    abort "Unexpected transport dependency" if defined?(Net::Connector) || Gem::Specification.find_all_by_name("net-connector").any?
    configuration = Wireless::Config.new.parse("sysname WLC\\nreturn\\n", complete: true)
    abort "Offline configuration parsing failed" unless configuration.complete?
    huawei = Wireless::RuntimeParser.new(platform: :huawei).parse(:access_points, "ID MAC Name Group IP Type State STA Uptime\\nTotal: 0\\n", complete: true)
    abort "Installed Huawei profile failed" unless huawei.complete? && huawei.records.empty?
    begin
      Wireless::RuntimeParser.new(platform: :huawei).parse(:access_points, "", complete: "false")
      abort "Invalid completeness accepted"
    rescue ArgumentError
    end
    loaded = Gem.loaded_specs.fetch("wireless-rb")
    abort "Loaded checkout instead of package" unless File.realpath(loaded.full_gem_path).start_with?(File.realpath(ENV.fetch("GEM_HOME")) + "/")
    abort "Version mismatch" unless loaded.version.to_s == #{spec.version.to_s.inspect}
    abort "Unexpected connector dependency" if loaded.runtime_dependencies.any? { |dependency| %w[net-connector dotenv].include?(dependency.name) }
    abort "Missing installed CLI guide" unless File.file?(File.join(loaded.full_gem_path, "bin/README.md"))
    abort "Missing executable" unless loaded.executables == [ "wireless" ]
    require "fileutils"
    FileUtils.chmod_R("a-w", loaded.full_gem_path)
    begin
      command = File.join(ENV.fetch("GEM_HOME"), "bin/wireless")
      system(command, "--help", exception: true)
      system(command, "--version", exception: true)
      system(command, "review", "--help", exception: true)
      system(command, "apply", "--help", exception: true)
      require "json"
      FileUtils.mkdir_p("saved/devices")
      File.write("saved/devices/ac.json", JSON.generate(schema_version: 4, kind: "collection", target: { name: "AC", host: "192.0.2.1", platform: "h3c" }, status: "complete", snapshot: { collection_status: "complete", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1", platform: "h3c" }, observations: { configuration: configuration.to_h } }))
      system(command, "review", "--batch", "saved", "--output", "reviews", exception: true)
      abort "Missing installed review artifacts" unless Dir["reviews/*/recommendations/*.txt"].size == 1 && Dir["reviews/*/review.txt"].size == 1
      abort "Unexpected Markdown review artifacts" unless Dir["reviews/**/*.md"].empty?

      system(command, "parse", "--help-all", exception: true)
      File.write("aps.txt", "Total number of APs : 0\\n")
      system(command, "parse", "--dimension", "access_points", "--complete", "--json", "--file", "aps.txt", exception: true)
      # 纯解析与帮助已在没有连接器的隔离安装中完成，再安装宿主配置可选依赖。
      expect_package = #{expect_artifact.inspect}
      system(RbConfig.ruby, "-S", "gem", "install", expect_package, "--local", "--no-document", exception: true) if expect_package
      connector_package = #{connector_artifact.inspect}
      installation = connector_package ? [ connector_package, "--local" ] : [ "net-connector", "--version", ">= 0.21.0, < 0.23" ]
      system(RbConfig.ruby, "-S", "gem", "install", *installation, "--no-document", exception: true)
      system(command, "collect", "--help-all", exception: true)
      system(command, "collect", "--init", "--non-interactive", exception: true)
      config = File.join(ENV.fetch("XDG_CONFIG_HOME"), "net-connector/wireless.yml")
      env_file = File.join(ENV.fetch("XDG_CONFIG_HOME"), "net-connector/.env")
      abort "Config missing" unless File.file?(config) && File.file?(env_file)
      abort "Initialization wrote into cwd" if File.exist?("wireless.yml") || File.exist?(".env")
      abort "Unsafe config permissions" unless File.stat(config).mode & 0o777 == 0o600
      require "yaml"
      abort "Unexpected report default" unless YAML.safe_load_file(config).fetch("directory") == File.join(Dir.pwd, "wireless-reports")
      File.write(config, YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
      system(command, "collect", "--plan", "--no-progress", exception: true)
      system(command, "collect", "--plan", "--env-file", "absent.env")
      abort "Missing explicit environment file accepted" unless $?.exitstatus == 2
      load File.join(loaded.full_gem_path, "examples/offline.rb")
    ensure
      FileUtils.chmod_R("u+w", loaded.full_gem_path)
    end
  RUBY
  system(env, ruby, "-e", check, chdir: home, exception: true)
end
