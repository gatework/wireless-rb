# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli/collect"
require "stringio"
require "tmpdir"

RSpec.describe Wireless::CLI::Options do
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @config, @envfile = File.join(directory, "selected.yml"), File.join(directory, ".env")
      @env, @out = {}, StringIO.new
      File.write(@envfile, "")
      example.run
    end
  end

  def options(*args)
    described_class.new(args, env: @env, out: @out, config: @config, env_file: @envfile, discovery: { directories: [ @directory ], home: @directory, cwd: @directory })
  end

  it "initializes a shared file that reloads with explicit values and source paths" do
    path = File.join(@directory, "net-connector.yml")
    directory = File.join(@directory, "reports")
    options("--init", "--config", path, "--parallel", "9", "--directory", directory).initialize_files
    expect(YAML.safe_load_file(path).keys).to eq([ "wireless" ])

    result = options("--config", path).load
    expect(result.values).to include("parallel" => 9, "directory" => directory)
    expect(result.sources.fetch("configuration_files")).to eq([ path ])
    expect(result.sources.fetch("fields").fetch("parallel")).to eq(path)
    expect(result.values.fetch("devices")).to eq([])
  end

  it "inherits later shared concurrency changes instead of freezing them in generated YAML" do
    File.write(@envfile, "NC_PARALLEL=50\nND_URL=https://inventory.example.test\n")
    options("--init").initialize_files
    expect(options.load.values.fetch("parallel")).to eq(50)
    File.write(@envfile, "NC_PARALLEL=30\nND_URL=https://inventory.example.test\n")
    expect(options.load.values.fetch("parallel")).to eq(30)
    File.write(@config, YAML.dump(YAML.safe_load_file(@config).merge("parallel" => 7)))
    expect(options.load.values.fetch("parallel")).to eq(7)
    @env["NC_PARALLEL"] = "8"
    expect(options.load.values.fetch("parallel")).to eq(8)
    expect(options("--parallel", "9").load.values.fetch("parallel")).to eq(9)
  end

  it "does not freeze a common process value because a lower layer has a tool-specific value" do
    File.write(@envfile, "WIRELESS_PARALLEL=4\nND_URL=https://inventory.example.test\n")
    @env["NC_PARALLEL"] = "50"
    options("--init").initialize_files
    @env.clear
    File.write(@envfile, "NC_PARALLEL=30\nND_URL=https://inventory.example.test\n")
    expect(options.load.values.fetch("parallel")).to eq(30)
  end

  it "loads env defaults without replacing process credentials or copying secrets into initialized YAML" do
    selected = File.join(@directory, "from-env.yml")
    @env["NC_DEVICE_USERNAME"] = "process-user"
    File.write(@envfile, "WIRELESS_CONFIG=#{selected}\nWIRELESS_PARALLEL=9\nWIRELESS_PLATFORM=huawei\nNC_DEVICE_USERNAME=file-user\nNC_DEVICE_PASSWORD='private#with$dollar'\n")
    settings = described_class.new([ "--init", "-p", "3" ], env: @env, out: @out, env_file: @envfile, discovery: { directories: [ @directory ], home: @directory, cwd: @directory })
    settings.load_environment
    settings.initialize_files
    expect(@env.fetch("NC_DEVICE_USERNAME")).to eq("process-user")
    expect(@env).not_to have_key("NC_DEVICE_PASSWORD")
    expect(settings.environment.fetch("NC_DEVICE_PASSWORD")).to eq('private#with$dollar')
    expect(YAML.safe_load_file(selected)).to include("parallel" => 3, "platform" => "huawei", "devices" => [])
    expect(File.read(selected) + @out.string).not_to include("private#with")
    expect(File.stat(selected).mode & 0o777).to eq(0o600)
  end

  it "preserves public SSH and cache environment choices when initializing templates" do
    @env.merge!("NC_HOST_KEY_POLICY" => "strict", "NC_KNOWN_HOSTS" => File.join(@directory, "keys"), "ND_CACHE_TTL" => "90")
    options("--init").initialize_files
    values = YAML.safe_load_file(@config)
    expect(values.fetch("ssh")).to include("host_key_policy" => "strict", "known_hosts" => File.join(@directory, "keys"))
    expect(values.fetch("netdisco")).to include("cache_ttl" => 90)
  end

  it "gives explicit config precedence over env and resolves public paths beside that YAML" do
    File.write(@config, YAML.dump("directory" => "reports", "netdisco_config" => "inventory.yml", "ssh" => { "known_hosts" => "keys" }))
    File.write(File.join(@directory, "inventory.yml"), YAML.dump("netdisco" => { "source" => "http" }))
    File.write(@envfile, "WIRELESS_CONFIG=missing.yml\n")
    settings = options("--config", @config)
    settings.load_environment
    values = settings.load.values
    expect(values.fetch("directory")).to eq(File.join(@directory, "reports"))
    expect(values.fetch("netdisco_config")).to eq(File.join(@directory, "inventory.yml"))
    expect(values.dig("ssh", "known_hosts")).to eq(File.join(@directory, "keys"))
  end

  it "applies environment defaults to an external inventory without creating a conflicting inline source" do
    File.write(@config, YAML.dump("netdisco_config" => "inventory.yml"))
    File.write(File.join(@directory, "inventory.yml"), YAML.dump("netdisco" => { "cache_ttl" => 90, "source" => "http" }))
    @env["ND_CACHE_TTL"] = "180"
    settings = options.load
    expect(settings.values).not_to have_key("netdisco")
    expect(settings.netdisco_settings.snapshot(mode: :inventory).inventory_cache_options.fetch(:ttl)).to eq(180)
  end

  it "does not consume input or create files for missing noninteractive configuration" do
    input = StringIO.new("yes\n")
    expect { described_class.new([ "--non-interactive" ], env: {}, out: @out, discovery: { directories: [ @directory ], home: @directory }).missing?(input: input, error: StringIO.new) }.to raise_error(ArgumentError, /--init/)
    expect(input.pos).to eq(0)
    expect(Dir.children(@directory)).to eq([ ".env" ])
  end

  it "keeps help independent of invalid environment and missing files" do
    @env["WIRELESS_PARALLEL"] = "invalid"
    expect(options("--help-all").informational?).to be(true)
    expect(Dir.children(@directory)).to eq([ ".env" ])
  end
end

RSpec.describe "Wireless layered configuration" do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @low, @high = %w[system working].map { |name| File.join(root, name) }
      [ @low, @high ].each { |path| FileUtils.mkdir_p(path) }
      @env = {}
      example.run
    end
  end

  def load_options(*arguments)
    Wireless::CLI::Options.new(arguments, env: @env, out: StringIO.new,
      discovery: { directories: [ @low, @high ], home: @root, cwd: @high }).load
  end

  it "merges layers, keeps source-relative paths and applies process environment above YAML" do
    File.write(File.join(@low, "net-connector.yml"), YAML.dump("common" => { "ssh" => { "known_hosts" => "keys" } }, "wireless" => { "parallel" => 3, "directory" => "reports" }))
    File.write(File.join(@high, "wireless.yml"), YAML.dump("platform" => "huawei", "parallel" => 5))
    File.write(File.join(@high, ".env"), "WIRELESS_PARALLEL=9\nNC_DEVICE_PASSWORD=private-source-secret\n")
    @env["WIRELESS_PARALLEL"] = "7"
    options = load_options
    expect(options.values).to include("parallel" => 7, "platform" => "huawei", "directory" => File.join(@low, "reports"))
    expect(options.values.dig("ssh", "known_hosts")).to eq(File.join(@low, "keys"))
    expect(options.sources.fetch("configuration_files")).to eq([ File.join(@low, "net-connector.yml"), File.join(@high, "wireless.yml") ])
    expect(options.sources.to_s).not_to include("private-source-secret")
    expect(@env).to eq("WIRELESS_PARALLEL" => "7")
    expect(load_options("-p", "11").values.fetch("parallel")).to eq(11)
  end

  it "uses YAML above env files while retaining source-relative environment paths" do
    File.write(File.join(@low, ".env"), "WIRELESS_PARALLEL=9\nNC_KNOWN_HOSTS=keys\n")
    File.write(File.join(@high, "wireless.yml"), YAML.dump("parallel" => 5))
    values = load_options.values
    expect(values.fetch("parallel")).to eq(5)
    expect(values.dig("ssh", "known_hosts")).to eq(File.join(@low, "keys"))
  end

  it "ignores a lower environment-file value when YAML provides the effective inventory value" do
    File.write(File.join(@low, ".env"), "ND_CACHE_TTL=invalid\n")
    File.write(File.join(@high, "wireless.yml"), YAML.dump("netdisco" => { "source" => "http", "cache_ttl" => 90 }))
    expect(load_options.values.dig("netdisco", "cache_ttl")).to eq(90)
  end

  it "applies CLI inventory choices before validating overridden environment values" do
    File.write(File.join(@high, "wireless.yml"), YAML.dump("netdisco" => { "source" => "postgres" }))
    @env.merge!("ND_SOURCE" => "", "ND_CACHE_MODE" => "")
    options = load_options("--source", "http", "--cache-only")
    expect(options.public_values.fetch("netdisco")).to include("source" => "http", "cache_mode" => "only")
    expect(options.netdisco_settings.public_config.fetch(:netdisco)).to include(source: :http, cache_mode: :only)
  end

  it "applies CLI inventory choices above invalid dotenv defaults" do
    File.write(File.join(@high, "wireless.yml"), YAML.dump("netdisco" => {}))
    File.write(File.join(@low, ".env"), "ND_SOURCE=\nND_CACHE_MODE=\n")
    options = load_options("--source", "http", "--refresh-inventory")
    expect(options.public_values.fetch("netdisco")).to include("source" => "http", "cache_mode" => "refresh")
    expect(options.netdisco_settings.public_config.fetch(:netdisco)).to include(source: :http, cache_mode: :refresh)
  end

  it "does not inject common dynamic inventory into an explicitly static tool inventory" do
    File.write(File.join(@low, "net-connector.yml"), YAML.dump("common" => { "netdisco" => { "source" => "http" } }))
    File.write(File.join(@high, "wireless.yml"), YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
    expect(load_options.values).not_to have_key("netdisco")
    File.write(File.join(@high, "wireless.yml"), YAML.dump("devices" => [ { "host" => "192.0.2.10" } ], "netdisco" => { "source" => "http" }))
    expect { load_options }.to raise_error(ArgumentError, /不能同时/)
  end

  it "resolves external inventory paths once and previews the frozen effective inventory" do
    inventory = File.join(@low, "inventory.yml")
    File.write(inventory, YAML.dump("netdisco" => { "url" => "https://yaml.example.test", "cache_directory" => "cache" }))
    File.write(File.join(@high, "wireless.yml"), YAML.dump("netdisco_config" => inventory))
    @env["ND_URL"] = "https://process.example.test"
    @env["ND_API_KEY"] = "fixture-only-key"
    options = load_options
    File.write(inventory, "invalid: changed mid-batch")
    preview = options.public_values.fetch("inventory_configuration")
    expect(Net::Connector::Netdisco::Inventory::HTTP).to receive(:new).with(hash_including(api_key: "fixture-only-key")).and_call_original
    expect { options.netdisco_settings.inventory }.not_to raise_error
    expect(options.public_values.to_s).not_to include("fixture-only-key")
    expect(preview.dig("netdisco", "url")).to eq("https://process.example.test")
    expect(preview.dig("netdisco", "cache_directory")).to eq(File.join(@low, "cache"))
    expect(options.netdisco_settings.inventory_options[:url]).to eq(preview.dig("netdisco", "url"))
  end

  it "preserves libpq system trust for YAML and environment certificate settings" do
    path = File.join(@high, "wireless.yml")
    File.write(path, YAML.dump("netdisco" => { "source" => "http", "db_sslrootcert" => "system" }))
    expect(load_options.values.dig("netdisco", "db_sslrootcert")).to eq("system")
    File.write(path, YAML.dump("netdisco" => { "source" => "http" }))
    File.write(File.join(@low, ".env"), "ND_DB_SSLROOTCERT=system\n")
    expect(load_options.values.dig("netdisco", "db_sslrootcert")).to eq("system")
    @env["ND_DB_SSLROOTCERT"] = "system"
    expect(load_options.values.dig("netdisco", "db_sslrootcert")).to eq("system")
  end

  it "uses an explicit external inventory without inheriting common inline defaults" do
    File.write(File.join(@low, "net-connector.yml"), YAML.dump("common" => {
      "netdisco" => { "source" => "http" }, "inventory" => { "include_names" => [ "common" ] } }))
    path = File.join(@high, "wireless.yml")
    File.write(File.join(@high, "inventory.yml"), YAML.dump("netdisco" => { "source" => "http" }))
    File.write(path, YAML.dump("netdisco_config" => "inventory.yml"))
    values = load_options.values
    expect(values.fetch("netdisco_config")).to eq(File.join(@high, "inventory.yml"))
    expect(values).not_to have_key("netdisco")
    expect(values).not_to have_key("inventory")
    File.write(path, YAML.dump("netdisco_config" => "inventory.yml", "netdisco" => { "source" => "http" }))
    expect { load_options }.to raise_error(ArgumentError, /不能同时/)
  end

  it "isolates inventory settings from unrelated public environment policies" do
    File.write(File.join(@high, "wireless.yml"), YAML.dump("netdisco" => { "url" => "https://inventory.example.test" }))
    @env.merge!("NC_TOPOLOGY_DESCRIPTION_FORMAT" => "unused %{unknown}",
      "NC_TOPOLOGY_PARALLEL" => "unused-invalid", "NC_TFTP_VRFS" => "unused-invalid")
    expect(load_options.netdisco_settings.inventory_options.fetch(:url)).to eq("https://inventory.example.test")
  end

  it "validates only inventory sections in an external document and retains their source paths" do
    path = File.join(@low, "inventory.yml")
    document = { "netdisco" => { "url" => "https://inventory.example.test", "cache_directory" => "cache" },
      "inventory" => { "include_names" => [ "controller" ] }, "backup" => { "parallel" => 501 }, "ssh" => "unused-invalid" }
    File.write(path, YAML.dump(document))
    File.write(File.join(@high, "wireless.yml"), YAML.dump("netdisco_config" => path))
    options = load_options
    expect(options.values.fetch("parallel")).to eq(4)
    expect(options.public_values.fetch("inventory_configuration")).to eq(
      "netdisco" => { "url" => "https://inventory.example.test", "cache_directory" => File.join(@low, "cache") },
      "inventory" => { "include_names" => [ "controller" ] })
    File.write(path, YAML.dump(document.merge("netdisco" => { "page_size" => 0 })))
    expect { load_options }.to raise_error(ArgumentError, /page_size/)
  end

  it "rejects explicitly missing files and initializes only the user configuration directory" do
    expect { load_options("--env-file", File.join(@root, "missing.env")) }.to raise_error(ArgumentError, /missing.env/)
    options = Wireless::CLI::Options.new([ "--init" ], env: {}, out: StringIO.new,
      discovery: { directories: [ @low, @high ], home: @root, cwd: @high })
    options.load_environment
    options.initialize_files
    expect(File).to exist(File.join(@root, ".config/net-connector/wireless.yml"))
    expect(File).to exist(File.join(@root, ".config/net-connector/.env"))
    expect(Dir.children(@high)).to eq([])
  end
end
