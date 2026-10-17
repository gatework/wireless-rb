# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Wireless configuration integrity" do
  let(:parser) { Wireless::H3c::Parsers::DisplayCurrentConfiguration.new }

  it "removes conflicting settings in one template and keeps their source captures incomplete" do
    source = "wlan service-template LAB\n ssid Secure\n ssid Open\n ssid Secure\n vlan 100\nreturn\n"
    result = parser.parse(source, complete: true)
    expect(result.status).to eq(:partial)
    template = result.records.first[:service_templates].first
    expect(template).not_to have_key(:ssid)
    expect(template[:vlan_id]).to eq(100)
    expect(parser.cursor.state(1)).to eq(:invalid)
    expect(parser.cursor.state(2)).to eq(:invalid)
    expect(parser.cursor.captures_for([ :service_templates, 0 ]).first).not_to be_complete
  end

  it "never re-derives authentication from an ambiguous template" do
    source = "wlan service-template LAB\n akm mode dot1x\n client-security authentication-mode dot1x\n" \
      " client-security authentication-mode mac\n client-security authentication-mode dot1x\nreturn\n"
    result = parser.parse(source, complete: true)
    expect(result.status).to eq(:partial)
    template = result.records.first[:service_templates].first
    expect(template[:authentication_type]).to be_nil
    expect(template[:configuration]).not_to have_key(:client_security_authentication_mode)
  end

  it "rejects conflicting numeric and nested settings without losing unrelated scopes" do
    source = "wlan ap AP model TEST\n radio 1\n  channel 36\n  channel 40\n  channel 36\n" \
      "  packet-filter name FIRST inbound\n  packet-filter name SECOND inbound\n radio 2\n  radio enable\nreturn\n"
    result = parser.parse(source, complete: true)
    expect(result.status).to eq(:partial)
    radio = result.records.first.dig(:access_points, "AP", :radios, "1")
    expect(radio).not_to have_key(:channel)
    expect(radio).not_to have_key(:channel_number)
    expect(radio[:packet_filters]).not_to have_key(:inbound)
    expect(result.records.first.dig(:access_points, "AP", :radios, "2", :enabled)).to be(true)
  end

  it "accepts equivalent assignments and preserves intentional sequential scope captures" do
    source = "wlan service-template LAB\n ssid Secure\n ssid Secure\n vlan 010\n vlan 10\nreturn\n"
    expect(parser.parse(source, complete: true)).to be_complete
    source = "wlan global-configuration\n auto-ap enable\n#\nwlan global-configuration\n undo auto-ap enable\nreturn\n"
    result = parser.parse(source, complete: true)
    expect(result).to be_complete
    expect(parser.cursor.captures_for([ :global_settings ]).map { |capture| capture.data[:auto_ap] }).to eq([ true, false ])
  end
  it "does not certify absent wireless configuration hidden under an unsupported parent" do
    source = "sysname WLC\nfuture-scope\n wlan service-template HIDDEN\n  ssid Private\nreturn\n"
    result = parser.parse(source, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first[:service_templates]).to be_empty
    expect(result.issues).to include(include(code: :unrecognized_wireless_configuration, line: 3))
    expect(parser.cursor.state(2)).to eq(:unsupported)
  end

  it "skips authentication derivation after conflicting AKM lists instead of raising" do
    [ %w[dot1x psk], %w[psk dot1x] ].each do |modes|
      source = "wlan service-template LAB\n" + modes.map { |mode| " akm mode #{mode}\n" }.join + "return\n"
      result = parser.parse(source, complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:service_templates].first[:authentication_type]).to be_nil
    end
  end

  it "keeps conflicting root device identities unresolved through subsequent declarations" do
    result = parser.parse("sysname FIRST\nsysname SECOND\nsysname FIRST\nreturn\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first[:global_settings]).not_to have_key(:hostname)
    expect(parser.cursor.states.first(3)).to eq([ :invalid, :invalid, :invalid ])
  end
  it "validates AP model suffixes without changing model identity case" do
    [ "wlan ap AP model TEST trailing", "wlan ap AP model" ].each do |line|
      result = parser.parse("#{line}\nreturn\n", complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:access_points]).to be_empty
    end
    result = parser.parse("wlan ap AP MODEL Model-A\nreturn\n", complete: true)
    expect(result).to be_complete
    expect(result.records.first.dig(:access_points, "AP", :model)).to eq("Model-A")
  end
end
