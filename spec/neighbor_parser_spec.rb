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

  it "reports an unsupported platform dimension independently of caller validation" do
    parser = described_class.new(platform: :huawei)
    result = parser.parse("No LLDP neighbors\n", ap_name: "AP-LAB", complete: true)
    expect(result.status).to eq(:unsupported)
    expect(result.records).to be_empty
    expect { parser.parse(nil, ap_name: "AP-LAB") }.to raise_error(ArgumentError)
    expect { parser.parse("", ap_name: "AP-LAB", complete: "true") }.to raise_error(ArgumentError)
  end
end
