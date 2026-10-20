# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Wireless parser integrity" do
  let(:parser) { Wireless::RuntimeParser.new }
  let(:client) { "MAC address : 0200-0000-0101\n" }

  it "rejects contradictory or malformed totals throughout H3C and Huawei output" do
    [ "Total number of clients : 1\n#{client}Total number of clients : 2\n",
      "Total number of clients : invalid\n#{client}", "#{client}Total number of clients : 1 trailing\n", "#{client}Total clients in view : 1\n" ].each do |text|
      expect(parser.parse(:clients, text, complete: true)).not_to be_complete
    end
    header = "ID MAC Name Group IP Type State STA Uptime\n"
    text = "#{header}0 0200-0000-0007 AP-HW LAB 192.0.2.7 AP6050 nor 0 001:02:03:04\nTotal: 2\nTotal: 1\n"
    expect(parser.parse(:access_points, text, platform: :huawei, complete: true)).not_to be_complete
    expect(parser.parse(:blocked_clients, "0200-0000-0101 reason\nTotal: 1\nTotal: 2\n", complete: true)).not_to be_complete
  end

  it "removes conflicting converted values permanently while retaining unrelated facts" do
    text = "Total number of clients : 1\n#{client}VLAN ID : 10\nVLAN ID : 20\nVLAN ID : 10\nSSID : Corp\n"
    result = parser.parse(:clients, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(ssid: "Corp")
    expect(result.records.first).not_to have_key(:vlan)
    expect(result.issues).to include(include(code: :conflicting_field, line: 4))
    same = "Total number of clients : 1\n#{client}VLAN ID : 010\nVLAN ID : 10\n"
    expect(parser.parse(:clients, same, complete: true)).to be_complete
  end

  it "validates repeated compound measurements and BSS security" do
    result = parser.parse(:clients, "Total: 1\n#{client}Rx/Tx rate : 1/2 Mbps\nRx/Tx rate : 3/2 Mbps\nRx/Tx rate : 1/2 Mbps\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first).not_to have_key(:rx_rate_mbps)
    expect(result.records.first[:tx_rate_mbps]).to eq(2)
    text = "Total BSSs: 1\nBSSID : 0200-0000-0201\nAP name : AP-A\nRadio ID : 1\nSecurity mode : WPA2\nSecurity mode : Open\n"
    result = parser.parse(:bsses, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first.fetch(:security)).not_to have_key(:security_mode)
  end

  it "retains LLDP continuation text while rejecting conflicting neighbor fields and totals" do
    text = "LLDP neighbor-information of port 1[GE1]:\nLLDP neighbor index: 1\nChassis ID: switch\nPort ID: GE2\nSystem description: first\n  continuation\nTotal neighbors: 1\nTotal neighbors: 2\n"
    result = Wireless::NeighborParser.new.parse(text, ap_name: "AP-A", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first.dig(:details, :system_description)).to eq("first\ncontinuation")
    expect(result.issues).to include(include(code: :conflicting_total))
    result = Wireless::NeighborParser.new.parse(text.sub("Total neighbors: 2", "Port ID: GE3"), ap_name: "AP-A", complete: true)
    expect(result).not_to be_complete
    expect(result.records).to be_empty
  end

  it "keeps total-like lines inside LLDP system descriptions as ordinary text" do
    text = "LLDP neighbor-information of port 1[GE1]:\nLLDP neighbor index: 1\nChassis ID: switch\nPort ID: GE2\nSystem description: first\n  Total: 99\n  Total lines in description: 2\nTotal neighbors: 1\n"
    result = Wireless::NeighborParser.new.parse(text, ap_name: "AP-A", complete: true)
    expect(result).to be_complete
    expect(result.records.first.dig(:details, :system_description)).to eq("first\nTotal: 99\nTotal lines in description: 2")
  end

  it "normalizes band default identities and refuses malformed AP group suffixes" do
    result = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse("wlan ap-group LAB\n radio 5G\n  radio enable\nreturn\n", complete: true)
    expect(result).to be_complete
    expect(result.records.first[:ap_groups].first.dig(:configuration, :band_defaults, "5g", :enabled)).to be(true)
    result = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse("wlan ap-group LAB gibberish\nreturn\n", complete: true)
    expect(result).not_to be_complete
    expect(result.records.first[:ap_groups]).to be_empty
  end

  it "keeps AP system uptime distinct from controller online time" do
    result = parser.parse(:access_points, "Total APs: 1\nAP name: AP-A\nOnline time: 1h\nSystem uptime: 2h\n", complete: true)
    expect(result).to be_complete
    expect(result.records.first).to include(online_seconds: 3600, uptime_seconds: 7200)
  end

  it "uses explicit client authentication mode before stale domain references" do
    %w[mac mac-and-dot1x dot1x-then-mac mac-then-dot1x oui-then-dot1x].each do |mode|
      result = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse("wlan service-template LAB\n dot1x domain old\n client-security authentication-mode #{mode}\nreturn\n", complete: true)
      expect(result).to be_complete
      expect(result.records.first[:service_templates].first[:authentication_type]).to eq(mode == "mac" ? "mab" : mode)
    end
  end

  it "preserves opaque LLDP chassis identities while normalizing declared MAC identities" do
    text = "LLDP neighbor-information of port 1[GE1]:\nLLDP neighbor index: 1\nChassis ID: Router-A\nPort ID: GE2\n"
    result = Wireless::NeighborParser.new.parse(text, ap_name: "AP-A", complete: true)
    expect(result.records.first[:remote_chassis_id]).to eq("Router-A")
    text = text.sub("Router-A", "0200-0000-ABCD") + "Chassis type: MAC address\n"
    result = Wireless::NeighborParser.new.parse(text, ap_name: "AP-A", complete: true)
    expect(result.records.first[:remote_chassis_id]).to eq("02:00:00:00:ab:cd")
  end

  it "rejects configured VLAN zero without inventing a value for an optional binding" do
    text = "wlan service-template LAB\n vlan 0\nreturn\n"
    expect(Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse(text, complete: true)).not_to be_complete
    text = "wlan ap AP model TEST\n radio 1\n  service-template LAB\nreturn\n"
    result = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse(text, complete: true)
    expect(result).to be_complete
    expect(result.records.first.dig(:access_points, "AP", :radios, "1", :service_templates)).to eq([ { name: "LAB", vlan_id: nil } ])
  end

  it "does not infer admission authentication from an unused domain reference" do
    source = "wlan service-template LAB\n dot1x domain unused\n mac-authentication domain also-unused\nreturn\n"
    result = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse(source, complete: true)
    expect(result).to be_complete
    template = result.records.first[:service_templates].first
    expect(template[:authentication_type]).to be_nil
    expect(template[:configuration]).to include(dot1x_domain: "unused", mac_authentication_domain: "also-unused")
    result = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse(source.sub("dot1x domain unused", "client-security authentication-mode unknown"), complete: true)
    expect(result).not_to be_complete
    expect(result.records.first[:service_templates].first[:authentication_type]).to be_nil
  end

  it "enforces explicit IPv4 and IPv6 field families while retaining generic dual-stack addresses" do
    [ [ "IPv4 address", "2001:db8::1", :client_ip ], [ "IPv6 address", "192.0.2.1", :client_ipv6 ] ].each do |label, address, field|
      result = parser.parse(:clients, "Total: 1\n#{client}#{label}: #{address}\n", complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records.first).not_to have_key(field)
      result = parser.parse(:dot1x_connections, "Total connections: 1\nUser MAC address: 0200-0000-0101\n#{label}: #{address}\n", complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records.first).not_to have_key(label.start_with?("IPv4") ? :ip_address : :ipv6_address)
    end
    result = parser.parse(:clients, "Total: 1\n#{client}IP address: 2001:db8::1\n", complete: true)
    expect(result).to be_complete
    expect(result.records.first[:client_ip]).to eq("2001:db8::1")
  end

  it "rejects Huawei station IPv6 columns containing IPv4 addresses" do
    header = "STA MAC AP ID Ap name Rf/WLAN\n"
    text = "#{header}0200-0000-0101 1 AP-A 1/1 5G ax 1/2 -60 100 192.0.2.1 Lab run 192.0.2.2 0 1h\nTotal: 1\n"
    result = parser.parse(:clients, text, platform: :huawei, complete: true)
    expect(result).not_to be_complete
    expect(result.records).to be_empty
  end

  it "enforces the same VLAN bounds for Huawei stations and H3C clients" do
    [ 0, 4095 ].each do |vlan|
      text = "STA MAC AP ID Ap name Rf/WLAN\n0200-0000-0101 1 AP-A 1/1 5G ax 1/2 -60 #{vlan} 192.0.2.1 Lab run 2001:db8::1 0 1h\nTotal: 1\n"
      result = parser.parse(:clients, text, platform: :huawei, complete: true)
      expect(result).not_to be_complete
      expect(result.records).to be_empty
      result = parser.parse(:clients, "Total: 1\n#{client}VLAN ID: #{vlan}\n", complete: true)
      expect(result).not_to be_complete
      expect(result.records.first).not_to have_key(:vlan)
    end
    [ 1, 4094 ].each do |vlan|
      text = "STA MAC AP ID Ap name Rf/WLAN\n0200-0000-0101 1 AP-A 1/1 5G ax 1/2 -60 #{vlan} 192.0.2.1 Lab run 2001:db8::1 0 1h\nTotal: 1\n"
      result = parser.parse(:clients, text, platform: :huawei, complete: true)
      expect(result).to be_complete
      expect(result.records.first[:vlan]).to eq(vlan)
      result = parser.parse(:clients, "Total: 1\n#{client}VLAN ID: #{vlan}\n", complete: true)
      expect(result).to be_complete
      expect(result.records.first[:vlan]).to eq(vlan)
    end
  end

  it "keeps deep unsupported configuration subtrees partial without Ruby recursion" do
    text = "wlan ap AP model TEST\n" + (1..4000).map { |depth| " " * depth + "future-option\n" }.join + "return\n"
    result = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse(text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues.count { |issue| issue[:code] == :unrecognized_wireless_configuration }).to eq(4000)
  end

  it "preserves repeated template binding identity and rejects changed VLANs" do
    source = "wlan ap AP model TEST\n radio 1\n  service-template T vlan 100\n  service-template T vlan 100\n  service-template T vlan 200\nreturn\n"
    result = Wireless::H3c::Parsers::DisplayCurrentConfiguration.parse(source, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first.dig(:access_points, "AP", :radios, "1", :service_templates)).to eq([ { name: "T", vlan_id: 100 } ])
  end
  it "compares complete LLDP descriptions without mutating the registered prior value" do
    header = "LLDP neighbor-information of port 1[GE1]:\nLLDP neighbor index: 1\nChassis ID: Switch\nPort ID: GE2\n"
    description = "System description: first\n  continuation\n"
    result = Wireless::NeighborParser.new.parse(header + description * 2, ap_name: "AP", complete: true)
    expect(result).to be_complete
    expect(result.records.first.dig(:details, :system_description)).to eq("first\ncontinuation")
    text = header + description + description.sub("continuation", "different") + description
    result = Wireless::NeighborParser.new.parse(text, ap_name: "AP", complete: true)
    expect(result).to be_partial
    expect(result.records.first[:details]).not_to have_key(:system_description)
  end
end
