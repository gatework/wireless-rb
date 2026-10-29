# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli/collect"
require "net/connector/netdisco"
require "tmpdir"
require "stringio"

RSpec.describe "Wireless embedded Netdisco configuration" do
  around do |example|
    Dir.mktmpdir do |directory|
      @directory, @out, @error = directory, StringIO.new, StringIO.new
      @config = File.join(directory, "wireless.yml")
      @env = { "ND_URL" => "https://inventory.example.invalid", "ND_API_KEY" => "private-inventory-token",
        "NC_HOST_KEY_POLICY" => "accept_new", "ND_CACHE_TTL" => "180" }
      File.write(File.join(directory, "fixture.env"), "")
      example.run
    end
  end

  def run_cli(data, *args)
    File.write(@config, YAML.dump(data))
    Wireless::CLI::Collect.new(env: @env, input: StringIO.new, discovery: { directories: [ @directory ], home: @directory, cwd: @directory }, out: @out, error: @error).run(
      [ "--config", @config, "--env-file", File.join(@directory, "fixture.env"), *args ])
  end

  it "reads the inline source and applies YAML inventory rules through the real Catalog" do
    rows = [ { "ip" => "192.0.2.10", "name" => "WLC", "vendor" => "H3C", "model" => "WX3540" },
      { "ip" => "192.0.2.11", "name" => "Spare-WLC", "vendor" => "H3C", "model" => "WX3540" },
      { "ip" => "192.0.2.12", "name" => "Switch", "vendor" => "H3C", "model" => "S6520" } ]
    source = double("remote inventory", devices: rows)
    allow(Net::Connector::Netdisco::Catalog).to receive(:new).and_wrap_original do |original, **options|
      @settings = options.fetch(:settings)
      original.call(**options, inventory: source)
    end
    data = { "netdisco" => { "source" => "http", "cache_enabled" => false, "cache_ttl" => 90 },
      "inventory" => { "exclude_names" => [ "spare" ] } }
    expect(run_cli(data, "--plan", "--json")).to eq(0), @error.string
    expect(JSON.parse(@out.string).map { |d| d.fetch("host") }).to eq([ "192.0.2.10" ])
    expect(@settings.snapshot(mode: :inventory).inventory_cache_options.fetch(:ttl)).to eq(180)
    expect(@out.string + @error.string).not_to include("private-inventory-token")
  end

  it "rejects credential fields in nested public config before --show-config" do
    [ { "netdisco" => { "password" => "private-value" } }, { "inventory" => { "password" => "private-value" } } ].each do |data|
      expect(run_cli(data, "--show-config")).to eq(2)
      expect(@out.string).to eq("")
    end
    expect(@error.string).not_to include("private-value")
  end

  it "validates nested device rule fields before showing public configuration" do
    data = { "netdisco" => { "source" => "http" }, "inventory" => { "device_rules" => [
      { "vendor" => "H3C", "connector" => "h3c_wireless", "password" => "private-rule-secret" } ] } }
    expect(run_cli(data, "--show-config")).to eq(2)
    expect(@out.string).to eq("")
    expect(@error.string).not_to include("private-rule-secret")
  end

  it "validates public inventory rules without fetching inventory or requiring credentials" do
    @env.clear
    data = { "netdisco" => { "source" => "http" }, "inventory" => { "device_rules" => [
      { "vendor" => "H3C", "connector" => "h3c_wireless", "model_prefix" => "WX" } ] } }
    expect(run_cli(data, "--show-config")).to eq(0), @error.string
    expect(JSON.parse(@out.string).dig("inventory", "device_rules", 0, "model_prefix")).to eq("WX")
  end

  it "rejects conflicting inventory sources before any inventory read" do
    data = { "netdisco" => { "source" => "http" }, "devices" => [ { "host" => "192.0.2.10" } ] }
    expect(run_cli(data, "--plan")).to eq(2)
    expect(@out.string).to eq("")
  end

  it "shows CLI cache selection over YAML without fetching inventory" do
    data = { "netdisco" => { "source" => "http", "cache_mode" => "prefer", "cache_directory" => "cache" } }
    expect(run_cli(data, "--cache-only", "--show-config")).to eq(0), @error.string
    expect(JSON.parse(@out.string).fetch("netdisco")).to include("cache_mode" => "only", "cache_directory" => File.join(@directory, "cache"))
  end
end
