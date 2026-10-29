# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "yaml"

RSpec.describe "WIRELESS installed command" do
  let(:root) { File.expand_path("..", __dir__) }

  around do |example|
    Dir.mktmpdir do |home|
      @home = home
      FileUtils.mkdir_p(File.join(home, "bin"))
      FileUtils.cp(File.join(root, "bin/wireless"), File.join(home, "bin/wireless"))
      File.symlink(File.join(root, "lib"), File.join(home, "lib"))
      example.run
    end
  end

  def command(*args, directory: @home, stdin: "", env: {})
    cleared = ENV.keys.grep(/\A(?:WIRELESS_|NC_|ND_)/).to_h { |key| [ key, nil ] }
    Open3.capture3(cleared.merge("HOME" => @home, "XDG_CONFIG_HOME" => File.join(@home, "config"), **env), RbConfig.ruby, "-I#{root}/lib", "#{@home}/bin/wireless", *args,
      chdir: directory, stdin_data: stdin)
  end

  it "runs directly from the source bin directory without Bundler or RUBYLIB" do
    clean_env = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBY)/).to_h { |key| [ key, nil ] }
    %w[--help --version].each do |argument|
      stdout, stderr, status = Open3.capture3(clean_env, RbConfig.ruby, "wireless", argument, chdir: File.join(root, "bin"))
      expect(status).to be_success, stderr
      expect(stdout).to include(argument == "--version" ? Wireless::VERSION : "wireless collect")
    end
  end

  it "dispatches help, version and unknown commands without configuration" do
    stdout, stderr, status = command("--help")
    expect(status).to be_success, stderr
    expect(stdout).to include("wireless collect", "wireless parse")
    stdout, stderr, status = command("--version")
    expect(status).to be_success, stderr
    expect(stdout.strip).to eq(Wireless::VERSION)
    _stdout, stderr, status = command("unknown")
    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("--help")
  end

  it "parses evidence through the installed entry point" do
    stdout, stderr, status = command("parse", "--dimension", "access_points", "--complete", "--json", stdin: "Total number of APs : 0\n")
    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to include("status" => "complete", "records" => [])
  end

  it "reviews saved evidence without first loading the library or connector" do
    batch = File.join(@home, "saved")
    FileUtils.mkdir_p(File.join(batch, "devices"))
    document = { schema_version: 3, kind: "collection", device: { name: "WLC", host: "192.0.2.1", platform: "h3c_wireless" }, snapshot: nil }
    File.write(File.join(batch, "devices", "wlc.json"), JSON.generate(document))
    _stdout, stderr, status = command("review", "--batch", batch, "--output", File.join(@home, "reviews"))
    expect(status).to be_success, stderr
    summary = JSON.parse(File.read(Dir[File.join(@home, "reviews", "*", "review.json")].fetch(0)))
    expect(summary).to include("schema_version" => 3, "kind" => "review", "devices" => 1, "status" => "complete")
  end

  it "reports a missing collection dependency without a backtrace" do
    program = <<~RUBY
      require "wireless/cli"
      module Kernel
        alias original_require require
        def require(path)
          raise LoadError, "missing selection" if path == "net/connector/inventory/filters"
          original_require(path)
        end
      end
      exit Wireless::CLI.run(["collect", "--help"])
    RUBY
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{root}/lib", "-e", program)
    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("net-connector")
    expect(stderr).not_to include("LoadError", "<top (required)>")
  end

  it "loads the library and CLI without the connector or executing a command" do
    program = 'require "wireless/cli"; abort if defined?(Net::Connector); abort if $LOADED_FEATURES.any? { |f| f.include?("wireless/cli/collect") }'
    stdout, stderr, status = Bundler.with_unbundled_env { Open3.capture3(RbConfig.ruby, "-I#{root}/lib", "-e", program) }
    expect(status).to be_success, stderr
    expect(stdout).to eq("")
  end
  it "initializes in the user configuration directory and preserves existing files" do
    Dir.mktmpdir do |directory|
      stdout, stderr, status = command("collect", "--init", "--non-interactive", directory: directory)
      expect(status).to be_success, stderr
      config = File.join(@home, "config/net-connector/wireless.yml")
      env_file = File.join(@home, "config/net-connector/.env")
      expect(File).to exist(env_file)
      expect(YAML.safe_load_file(config).fetch("directory")).to eq(File.join(File.realpath(directory), "wireless-reports"))
      expect(File.stat(config).mode & 0o777).to eq(0o600)
      File.write(config, "preserve me")
      command("collect", "--init", directory: directory)
      expect(File.read(config)).to eq("preserve me")
      expect(stdout).to include(config)
      expect(Dir.children(directory)).to eq([])
    end
  end

  it "resolves YAML paths beside the config independently of cwd" do
    Dir.mktmpdir do |directory|
      config = File.join(directory, "wireless.yml")
      File.write(config, YAML.dump("devices" => [], "directory" => "reports", "ssh" => { "known_hosts" => "keys" }))
      stdout, stderr, status = command("collect", "--config", config, "--show-config")
      expect(status).to be_success, stderr
      values = JSON.parse(stdout)
      expect(values.fetch("directory")).to eq(File.join(directory, "reports"))
      expect(values.dig("ssh", "known_hosts")).to eq(File.join(directory, "keys"))
    end
  end

  it "supports the reference examples help and preview conventions" do
    %w[collect parse].each do |name|
      %w[-h --help-all --examples].each do |flag|
        stdout, stderr, status = command(name, flag)
        expect(status).to be_success, stderr
        expect(stdout).to include("wireless #{name}")
      end
    end
    Dir.mktmpdir do |directory|
      config = File.join(directory, "wireless.yml")
      File.write(config, YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
      stdout, stderr, status = command("collect", "--config", config, "--plan", "--json", "--no-progress")
      expect(status).to be_success, stderr
      expect(JSON.parse(stdout).map { |device| device.fetch("host") }).to eq([ "192.0.2.10" ])
      expect(stderr).to eq("")
      expect(Dir).not_to exist(File.join(directory, "wireless-reports"))
    end
  end

  it "explains initialization and rejects forced interaction in automation" do
    Dir.mktmpdir do |directory|
      stdout, stderr, status = command("collect", "--init", "--non-interactive", directory: directory)
      expect(status).to be_success, stderr
      expect(stdout).to include("本次未读取清单、未连接设备", "再次运行")
      _stdout, stderr, status = command("collect", "--interactive", "--config", "missing.yml", directory: directory)
      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("--interactive 需要交互终端")
    end
  end
  it "uses the default config when WIRELESS_CONFIG is blank in the process or env file" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "wireless.yml"), YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
      _stdout, stderr, status = command("collect", "--plan", directory: directory, env: { "WIRELESS_CONFIG" => "   " })
      expect(status).to be_success, stderr
      File.write(File.join(directory, ".env"), "WIRELESS_CONFIG='   '\n")
      _stdout, stderr, status = command("collect", "--plan", directory: directory)
      expect(status).to be_success, stderr
    end
  end
end
