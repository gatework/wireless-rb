# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Wireless::NeighborParser do
  let(:fixture) { File.read(File.expand_path("fixtures/netstack/wireless_lldp.txt", __dir__)) }

  it "parses link identities and management addresses independently of asset discovery" do
    parsed = described_class.new.parse(fixture, ap_name: "AP-LAB", complete: true)
    expect(parsed).to be_complete
    expect(only_record(parsed.records)).to include(ap_name: "AP-LAB", local_interface: "GigabitEthernet1/0/1",
      remote_interface: "GigabitEthernet1/0/24", remote_chassis_id: "0200-0000-1001", management_address: "192.0.2.254")
  end

  it "distinguishes empty neighbors from truncated or unidentified output" do
    expect(described_class.new.parse("No LLDP neighbors\n", ap_name: "AP-LAB", complete: true)).to be_complete
    expect(described_class.new.parse("", ap_name: "AP-LAB", complete: true).status).to eq(:failed)
    expect(described_class.new.parse(fixture, ap_name: "AP-LAB")).to be_partial
    expect(described_class.new.parse(fixture.sub("Port ID : GigabitEthernet1/0/24\n", ""), ap_name: "AP-LAB", complete: true).status).to eq(:failed)
  end

  it "rejects caller mistakes before treating device output as failed evidence" do
    parser = described_class.new
    [ nil, "", "  ", :ap ].each do |name|
      expect { parser.parse("No LLDP neighbors\n", ap_name: name, complete: true) }.to raise_error(ArgumentError)
    end
    expect { parser.parse(nil, ap_name: "AP-LAB") }.to raise_error(ArgumentError)
    expect { parser.parse("No LLDP neighbors\n", ap_name: "AP-LAB", complete: "true") }.to raise_error(ArgumentError)
    expect(parser.parse("\xff".b, ap_name: "AP-LAB", complete: true).status).to eq(:failed)
  end

  it "accepts an explicit empty neighbor list inside a port scope" do
    result = described_class.new.parse("LLDP neighbor-information of port 1[GE1]:\nNo neighbors\n",
      ap_name: "AP-LAB", complete: true)
    expect(result).to be_complete
    expect(result.records).to be_empty
  end

  it "keeps an empty port separate from another port with neighbors" do
    text = "LLDP neighbor-information of port 1[GE1]:\nNo LLDP neighbors\n" \
      "LLDP neighbor-information of port 2[GE2]:\nLLDP neighbor index: 1\nChassis ID: switch\nPort ID: GE3\n"
    result = described_class.new.parse(text, ap_name: "AP-LAB", complete: true)
    expect(result).to be_complete
    expect(result.records.size).to eq(1)
    expect(result.records.first[:local_interface]).to eq("GE2")
  end

  it "rejects contradictory empty and populated evidence for the same port in either order" do
    port = "LLDP neighbor-information of port 1[GE1]:\n"
    neighbor = "LLDP neighbor index: 1\nChassis ID: switch\nPort ID: GE2\n"
    [ port + neighbor + "No neighbors\n", port + "No neighbors\n" + neighbor ].each do |text|
      result = described_class.new.parse(text, ap_name: "AP-LAB", complete: true)
      expect(result).to be_partial
      expect(result.records.size).to eq(1)
      expect(result.issues).to include(include(code: :conflicting_neighbor_count))
    end
  end

  it "reports an unsupported platform dimension independently of caller validation" do
    parser = described_class.new(platform: :huawei)
    result = parser.parse("No LLDP neighbors\n", ap_name: "AP-LAB", complete: true)
    expect(result.status).to eq(:unsupported)
    expect(result.records).to be_empty
    expect { parser.parse(nil, ap_name: "AP-LAB") }.to raise_error(ArgumentError)
    expect { parser.parse("", ap_name: "AP-LAB", complete: "true") }.to raise_error(ArgumentError)
  end
end
