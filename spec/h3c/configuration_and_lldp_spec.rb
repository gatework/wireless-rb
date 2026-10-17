# frozen_string_literal: true

require_relative "../spec_helper"
require "open3"
require "rbconfig"
require "wireless/h3c/parsers/display_current_configuration"
require "wireless/h3c/parsers/display_lldp_neighbor_information_verbose"

RSpec.describe Wireless::H3c::Parsers::DisplayCurrentConfiguration do
  let(:fixture) { File.read(File.expand_path("../fixtures/netstack/wireless_details.cfg", __dir__)) }

  it "projects group and template settings from text without retaining configured secrets" do
    result = described_class.parse(fixture, complete: true)
    expect(result).to be_a(CtxParser::Result)
    expect(result).to be_complete
    config = result.records.fetch(0)
    expect(config[:ap_groups].size).to eq(2)
    expect(config[:service_templates].map { |template| template.values_at(:name, :authentication_type, :enabled) })
      .to eq([ [ "EAP", "dot1x", true ], [ "GUEST", "psk", false ], [ "UNKNOWN", nil, nil ] ])
    expect(config[:service_templates][1].dig(:configuration, :has_preshared_key)).to be(true)
    expect(result.to_h.inspect).not_to include("SYNTHETIC-PRIVATE-PSK")
    expect(result.to_h.keys).to eq(%i[status records issues])
  end

  it "retains partial configuration while rejecting unknown and invalid CLI output" do
    expect(described_class.parse(fixture).status).to eq(:partial)
    expect(described_class.parse("unrecognized output", complete: true).status).to eq(:failed)
    [ fixture + "wlan unsupported secret PRIVATE\n", fixture + "wlan ap-group LAB\n" ].each do |text|
      result = described_class.parse(text, complete: true)
      expect(result.status).to eq(:partial)
      expect(result.to_h.inspect).not_to include("PRIVATE")
    end
    expect { described_class.parse(nil, complete: true) }.to raise_error(ArgumentError, "Parser input must be text")
    [ "\xFF".b, "sysname WLC\0\n" ].each do |text|
      result = described_class.parse(text, complete: true)
      expect(result.status).to eq(:failed)
      expect(result.issues).to include(code: :invalid_output)
    end
  end

  it "loads and parses configuration and LLDP without Rails or Active Support" do
    root = File.expand_path("../..", __dir__)
    code = <<~'CODE'
      root = ARGV.fetch(0)
      require "wireless/h3c/parsers/display_current_configuration"
      require "wireless/h3c/parsers/display_lldp_neighbor_information_verbose"
      configuration = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse(
        File.read("#{root}/spec/fixtures/netstack/wireless_details.cfg"), complete: true)
      neighbors = Wireless::H3c::Parsers::DisplayLldpNeighborInformationVerbose.parse(
        File.read("#{root}/spec/fixtures/netstack/wireless_lldp.txt"), complete: true)
      abort "Incomplete parse" unless configuration.complete? && neighbors.complete?
      abort "Framework dependency" if defined?(Rails) || $LOADED_FEATURES.any? { |path| path.include?("active_support") }
      abort "External AP identity" if neighbors.records.any? { |record| record.key?(:ap_name) }
    CODE
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup", "-I", File.join(root, "lib"), "-e", code, root)
    expect(status.success?).to be(true), [ stdout, stderr ].join("\n")
  end
end

RSpec.describe Wireless::H3c::Parsers::DisplayLldpNeighborInformationVerbose do
  let(:fixture) { File.read(File.expand_path("../fixtures/netstack/wireless_lldp.txt", __dir__)) }

  it "extracts link endpoints directly from CLI text without an AP argument" do
    result = described_class.parse(fixture, complete: true)
    expect(result).to be_complete
    expect(result.records.fetch(0)).to include(local_interface: "GigabitEthernet1/0/1",
      remote_interface: "GigabitEthernet1/0/24", remote_chassis_id: "0200-0000-1001", management_address: "192.0.2.254")
    expect(result.records.fetch(0)).not_to have_key(:ap_name)
  end

  it "distinguishes explicit empty neighbors from incomplete and unidentified output" do
    expect(described_class.parse("No LLDP neighbors\n", complete: true)).to be_complete
    expect(described_class.parse("", complete: true).status).to eq(:failed)
    expect(described_class.parse(fixture).status).to eq(:partial)
    text = fixture.sub("Port ID : GigabitEthernet1/0/24\n", "")
    expect(described_class.parse(text, complete: true).status).to eq(:failed)
  end

  it "deduplicates link endpoints while retaining uncertainty" do
    result = described_class.parse(fixture * 2, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.size).to eq(1)
    expect(result.issues).to include(code: :duplicate_identity)
  end

  it "preserves wrapped descriptions and isolates invalid management addresses" do
    text = fixture.sub("System description : Synthetic laboratory switch\n", "System description : Synthetic laboratory switch\n  second description line\n")
    expect(described_class.parse(text, complete: true).records.fetch(0).dig(:details, :system_description))
      .to eq("Synthetic laboratory switch\nsecond description line")
    result = described_class.parse(text.sub("192.0.2.254", "300.0.2.254"), complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :invalid_management_address))
    expect(result.records.fetch(0)).not_to have_key(:management_address)
  end
end
