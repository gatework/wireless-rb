# frozen_string_literal: true

require_relative "spec_helper"
require "json"

RSpec.describe Wireless::Configuration do
  let(:fixture) { File.read(File.expand_path("fixtures/netstack/wireless_details.cfg", __dir__)) }

  it "extracts existing group/template fields and never retains a configured PSK" do
    parsed = described_class.new.parse(fixture, complete: true)
    expect(parsed).to be_complete
    config = only_record(parsed.records)
    expect(config[:ap_groups].size).to eq(2)
    expect(config[:service_templates].map { |template| template.values_at(:name, :authentication_type, :enabled) })
      .to eq([ [ "EAP", "dot1x", true ], [ "GUEST", "psk", false ], [ "UNKNOWN", nil, nil ] ])
    expect(config[:service_templates][1].dig(:configuration, :has_preshared_key)).to be(true)
    expect(parsed.to_h.to_json).not_to include("SYNTHETIC-PRIVATE-PSK")
  end

  it "keeps AP model/radio scopes separate and rejects bindings in an Ethernet scope" do
    source = <<~CLI
      wlan ap-group LAB
       ap-model MODEL-A
        radio 1
         service-template EAP vlan 100
        radio 2
         service-template GUEST vlan 200
       ap-model MODEL-B
        radio 1
         service-template EAP vlan 300
      #
      wlan ap AP-1 model MODEL-A
       radio 1
        service-template EAP vlan 100
       gigabitethernet 1
        service-template GUEST vlan 200
      return
    CLI
    parsed = described_class.new.parse(source, complete: true)
    expect(parsed).to be_partial
    config = only_record(parsed.records)
    profiles = only_record(config[:ap_groups])[:model_profiles]
    expect(profiles.dig("MODEL-A", :radios, "2", :service_templates)).to eq([ { name: "GUEST", vlan_id: 200 } ])
    expect(profiles.dig("MODEL-B", :radios, "1", :service_templates)).to eq([ { name: "EAP", vlan_id: 300 } ])
    expect(config.dig(:access_points, "AP-1", :radios, "1", :service_templates)).to eq([ { name: "EAP", vlan_id: 100 } ])
  end

  it "does not authorize destructive configuration projection for truncated unknown or duplicate input" do
    expect(described_class.new.parse(fixture)).to be_partial
    [ fixture + "wlan unsupported secret PRIVATE\n", fixture + "wlan ap-group LAB\n", fixture.sub("vlan 120", "vlan 9999") ].each do |text|
      parsed = described_class.new.parse(text, complete: true)
      expect(parsed).to be_partial
      expect(parsed.to_h.to_json).not_to include("PRIVATE")
    end
    expect(described_class.new.parse("unrecognized output", complete: true).status).to eq(:failed)
  end

  it "accepts a complete configuration without wireless sections as explicitly empty" do
    parsed = described_class.new.parse("sysname WLC\ninterface Vlan-interface1\n ip address 192.0.2.1 24\n#\nreturn\n", complete: true)
    expect(parsed).to be_complete
    expect(only_record(parsed.records).values_at(:ap_groups, :service_templates)).to eq([ [], [] ])
  end
end
