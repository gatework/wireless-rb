# frozen_string_literal: true

require_relative "spec_helper"
require "json"

RSpec.describe Wireless::RuntimeParser do
  let(:parser) { described_class.new }
  let(:ap_text) do
    <<~CLI
      Total number of APs : 1
      AP name : AP-LAB
      AP ID : 7
      MAC address : 0200-0000-0007
      IP address : 192.0.2.7
      State : Run
      Radio 1 :
       Admin state : Up
       Radio type : 802.11ax 6GHz
       Channel : 1(auto)
       Channel bandwidth : 80MHz
       Operating bandwidth : 40MHz
       Channel usage(%) : 0
       Noise floor : -90 dBm
       Max power : 20
    CLI
  end

  it "rejects inline pagination and editing controls before parsing runtime facts" do
    [ "--More--", "-- More --", "broken\e[31mname", "broken\bname", "broken\x7fname" ].each do |name|
      output = ap_text.sub("AP name : AP-LAB", "AP name : #{name}")
      observations = parser.parse_many(%i[access_points radios], output, complete: true)
      observations.each_value do |observation|
        expect(observation.status).to eq(:partial)
        expect(observation.records).to be_empty
        expect(observation.issues).to include(include(code: :invalid_terminal_output, line: 2))
      end
    end
  end

  it "applies terminal validation to standalone command parsers and Huawei observations" do
    parsed = Wireless::H3c::Parsers::DisplayWlanApAllVerbose.parse(ap_text.sub("AP-LAB", "AP--More--LAB"), complete: true)
    expect(parsed.status).to eq(:partial)
    expect(parsed.records).to be_empty
    parsed = parser.parse(:access_points, "Total : 0\n-- More --\n", platform: :huawei, complete: true)
    expect(parsed.status).to eq(:partial)
    expect(parsed.issues).to eq([ { code: :invalid_terminal_output, line: 2 } ])
  end

  it "parses shared AP/radio output into queryable fields and keeps configured power separate" do
    ap = parser.parse(:access_points, ap_text.b, complete: true)
    radio = parser.parse(:radios, ap_text, complete: true)
    expect(ap).to be_complete
    expect(only_record(ap.records)).to include(name: "AP-LAB", ap_id: "7", mac_address: "02:00:00:00:00:07", management_ip: "192.0.2.7")
    expect(radio).to be_complete
    expect(only_record(radio.records)).to include(ap_name: "AP-LAB", radio_id: "1", channel: 1, channel_width: 40, utilization: 0, noise_dbm: -90)
    expect(only_record(radio.records)).not_to have_key(:tx_power_dbm)
    expect(only_record(radio.records).dig(:details, :max_power)).to eq("20")
  end

  it "marks count mismatches, unknown lines and truncated responses incomplete" do
    [ ap_text.sub("APs : 1", "APs : 2"), ap_text + "Unsupported measurement : 40\n" ].each do |body|
      expect(parser.parse(:access_points, body, complete: true)).to be_partial
      expect(parser.parse(:radios, body, complete: true)).to be_partial
    end
    expect(parser.parse(:access_points, ap_text)).to be_partial
    expect(parser.parse(:access_points, "", complete: true).status).to eq(:failed)
  end

  it "retains a wrapped PoE status and refuses anonymous fields outside that known continuation" do
    text = ap_text.sub("Radio 1 :", "PoE status : Port 2\n           : Disabled\nRadio 1 :")
    ap = parser.parse(:access_points, text, complete: true)

    expect(ap).to be_complete
    expect(only_record(ap.records).dig(:details, :poe_status)).to eq("Port 2\nDisabled")
    expect(parser.parse(:radios, text, complete: true)).to be_complete
    expect(parser.parse(:access_points, ap_text + " : Unknown\n", complete: true)).to be_partial
  end

  it "requires a valid identity and does not use a total count to hide rejected rows" do
    parsed = parser.parse(:access_points, ap_text.sub("AP name : AP-LAB", "AP name : --"), complete: true)
    expect(parsed.status).to eq(:failed)
    expect(parsed.records).to be_empty
    expect(parsed.issues).to include(code: :count_mismatch, expected: 1, parsed: 0)
  end

  it "accepts explicit empty inventories and rejects duplicate identities" do
    expect(parser.parse(:clients, "Total number of clients : 0\n", complete: true)).to be_complete
    text = "Total number of clients : 2\nMAC address : 0200-0000-0001\nMAC address : 0200-0000-0001\n"
    value = parser.parse(:clients, text, complete: true)
    expect(value).to be_partial
    expect(value.records.size).to eq(1)
    expect(value.issues).to include(code: :duplicate_identity)
  end

  it "supports AP-name-first BSS blocks and a service VLAN without mixing the next AP" do
    text = <<~CLI
      Current BSS number : 2
      AP name : AP-A
      Radio ID : 1
      BSSID : 0200-0000-0201
      SSID : Lab A
      Service VLAN ID : 120
      AP name : AP-B
      Radio ID : 2
      BSSID : 0200-0000-0202
      SSID : Lab B
      VLAN ID : 121
    CLI
    parsed = parser.parse(:bsses, text, complete: true)
    expect(parsed).to be_complete
    expect(parsed.records.map { |row| row.values_at(:ap_name, :radio_id, :vlan, :service_vlan) }).to eq([ [ "AP-A", "1", nil, 120 ], [ "AP-B", "2", 121, nil ] ])
  end

  it "keeps relative RSSI distinct from dBm and converts rates and durations explicitly" do
    text = "Total number of clients : 1\nMAC address : 0200-0000-0101\nRSSI : 18\nRx/Tx rate : 5500/12000 Kbps\nOnline time : 1d 2h 3m 4s\n"
    parsed = parser.parse(:clients, text, complete: true)
    expect(parsed).to be_complete
    expect(only_record(parsed.records)).to include(rssi: 18, rx_rate_mbps: 5.5, tx_rate_mbps: 12, online_seconds: 93_784)
    expect(only_record(parsed.records)).not_to have_key(:signal_dbm)
    negative = parser.parse(:clients, text.sub("RSSI : 18", "RSSI : -62 dBm"), complete: true)
    expect(only_record(negative.records)).to include(signal_dbm: -62)
    expect(only_record(negative.records)).not_to have_key(:rssi)
  end

  it "does not serialize authorization URLs or sensitive unknown fields" do
    text = "Total number of connections : 1\nUser MAC address : 0200-0000-0101\nAuthorization URL : https://user:private-password@example.test\nUnknown password : private-password\n"
    parsed = parser.parse(:dot1x_connections, text, complete: true)
    expect(parsed).to be_partial
    expect(only_record(parsed.records).dig(:details, :authorization_url)).to be(true)
    expect(parsed.to_h.to_json).not_to include("private-password", "example.test", "Unknown password")
  end

  it "rejects invalid measurements without replacing them with plausible zeroes" do
    parsed = parser.parse(:radios, ap_text.sub("Channel usage(%) : 0", "Channel usage(%) : 101"), complete: true)
    expect(parsed).to be_partial
    expect(only_record(parsed.records)[:utilization]).to be_nil
    expect(parser.parse(:clients, "\xff".b, complete: true).status).to eq(:failed)
    expect(parser.parse(:clients, "% Unrecognized command found at '^' position.\n", complete: true).status).to eq(:unsupported)
  end

  it "retains blocked clients and distinguishes an unsupported Huawei dimension" do
    parsed = parser.parse(:blocked_clients, "MAC address Reason\n0200-0000-0001 Repeated failure\nTotal: 1\n", complete: true)
    expect(parsed).to be_complete
    expect(only_record(parsed.records)).to eq(mac_address: "02:00:00:00:00:01", reason: "Repeated failure")
    expect(parser.parse(:blocked_clients, "No blocked clients\n", complete: true)).to be_complete
    expect(parser.parse(:radios, "", platform: "huawei", complete: true).status).to eq(:unsupported)
  end

  it "parses Huawei AP rows and refuses a header without complete empty evidence" do
    header = "ID MAC Name Group IP Type State STA Uptime\n"
    text = "#{header}0 0200-0000-0007 AP-HW LAB 192.0.2.7 AP6050 nor 0 001:02:03:04\nTotal: 1\n"
    parsed = parser.parse(:access_points, text, platform: "huawei", complete: true)
    expect(parsed).to be_complete
    expect(only_record(parsed.records)).to include(operational_status: "online", client_count: 0, uptime_seconds: 93_784)
    expect(parser.parse(:access_points, header, platform: "huawei", complete: true).status).to eq(:failed)
  end
  it "rejects malformed dimension requests before interpreting device output" do
    [ nil, :clients, "clients", [], [ "clients" ], [ :clients, :clients ] ].each do |names|
      expect { parser.parse_many(names, "Total clients: 0\n", complete: true) }.to raise_error(ArgumentError)
    end
  end
end
