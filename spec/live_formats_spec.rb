# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "H3C live output formats" do
  let(:parser) { Wireless::RuntimeParser.new(platform: :h3c) }

  it "separates AP totals from connection and license counters" do
    text = <<~CLI
      Total number of APs: 1
      Total number of connected APs: 1
      Total number of connected manual APs: 1
      Total number of connected auto APs: 0
      Total number of connected common APs: 1
      Total number of connected WTUs: 0
      Total number of inside APs: 0
      Total AP licenses: 64
      AP name: AP-LAB
      Radio 1:
       Admin state: Up
    CLI
    results = parser.parse_many(%i[access_points radios], text, complete: true)
    expect(results.values).to all(be_complete)
    expect(results[:access_points].records.size).to eq(1)
    expect(results[:radios].records.size).to eq(1)
    [ "Total AP licenses: invalid", "Total unknown counters: 1", "Total number of APs: 2" ].each do |invalid|
      expect(parser.parse(:access_points, text + invalid + "\n", complete: true)).not_to be_complete
    end
  end

  it "recognizes block table entry totals while retaining malformed and contradictory evidence" do
    result = parser.parse(:blocked_clients, "Total entries: 0\n", complete: true)
    expect(result).to be_complete
    expect(result.records).to be_empty
    expect(parser.parse(:blocked_clients, "Total entries: 1\n0200-0000-0001 reason\n", complete: true)).to be_complete
    [ "Total entries: bad\n", "Total entries: 0\nTotal entries: 1\n", "Total entries: 0\n0200-0000-0001 reason\n" ].each do |text|
      expect(parser.parse(:blocked_clients, text, complete: true)).not_to be_complete
    end
  end

  it "preserves VLAN and service VLAN independently in clients and BSS records" do
    { clients: "MAC address: 0200-0000-0001\n", bsses: "AP name: AP-LAB\nBSSID: 0200-0000-0001\nRadio ID: 1\n" }.each do |dimension, identity|
      [ [ "N/A", nil ], [ "200", 200 ] ].each do |raw, expected|
        result = parser.parse(dimension, "Total: 1\n#{identity}VLAN ID: 100\nService VLAN ID: #{raw}\n", complete: true)
        expect(result).to be_complete
        expect(result.records.first).to include(vlan: 100, service_vlan: expected)
      end
      result = parser.parse(dimension, "Total: 1\n#{identity}VLAN ID: 100\nService VLAN ID: 200\nService VLAN ID: 300\n", complete: true)
      expect(result).not_to be_complete
      expect(result.records.first).to include(vlan: 100)
      expect(result.records.first).not_to have_key(:service_vlan)
    end
  end

  it "keeps spatial power saving state separate from its mode" do
    text = "Total: 1\nMAC address: 0200-0000-0001\nSM power save: Enabled\nSM power save mode: Dynamic\n"
    result = parser.parse(:clients, text, complete: true)
    expect(result).to be_complete
    expect(result.records.first).to include(power_save: "Enabled", power_save_mode: "Dynamic")
    expect(parser.parse(:clients, text + "SM power save mode: Static\n", complete: true)).not_to be_complete
  end

  it "accumulates cipher suites and security IEs within a service template" do
    text = "wlan service-template LAB\n akm mode psk\n cipher-suite ccmp\n cipher-suite tkip\n cipher-suite ccmp\n security-ie rsn\n security-ie wpa\nreturn\n"
    result = parser.parse(:configuration, text, complete: true)
    expect(result).to be_complete
    template = result.records.first[:service_templates].first
    expect(template[:configuration]).to include(cipher_suites: %w[ccmp tkip], security_ies: %w[rsn wpa])
    expect(template[:authentication_type]).to eq("psk")
  end

  it "does not certify an empty client response or a changing client count" do
    expect(parser.parse(:clients, "", complete: true)).not_to be_complete
    text = "Total number of clients: 1\nMAC address: 0200-0000-0001\nMAC address: 0200-0000-0002\n"
    expect(parser.parse(:clients, text, complete: true).issues).to include(include(code: :count_mismatch))
  end
end
