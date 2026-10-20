# frozen_string_literal: true

require_relative "spec_helper"
require "json"

RSpec.describe "Wireless remediation recommendations" do
  def review(template, complete: true, extra: {})
    observation = Wireless::Config.new(platform: :h3c_wireless).parse(template, complete: complete)
    document = JSON.parse(JSON.generate(device: { platform: "h3c_wireless", host: "192.0.2.1", name: "AC" }, snapshot: { dimensions: { configuration: observation.to_h }.merge(extra) }))
    Wireless::Recommendations.new(document).call
  end

  let(:config) do
    "wlan service-template lab\n ssid Lab\n cipher-suite ccmp\n cipher-suite tkip\n security-ie rsn\n security-ie wpa\n service-template enable\n#\n"
  end

  it "offers reversible hardening only as a candidate with service interruption prerequisites" do
    item = review(config)[:items].find { |r| r[:code] == "legacy_wlan_security" }
    expect(item).to include(status: "candidate")
    expect(item[:commands]).to eq([ "system-view", "wlan service-template lab", " undo service-template enable", " undo security-ie wpa", " undo cipher-suite tkip", " service-template enable", "quit", "return" ])
    expect(item[:rollback]).to include(" cipher-suite tkip", " security-ie wpa")
    expect(item[:prerequisites]).not_to be_empty
  end

  it "does not enable a service whose administrative state is unknown" do
    item = review(config.sub(" service-template enable\n", ""))[:items].find { |r| r[:code] == "legacy_wlan_security" }
    expect(item).to include(status: "blocked", commands: [])
  end

  it "does not remove the only cipher or generate scripts from incomplete configuration" do
    [ review(config.sub(" cipher-suite ccmp\n", "")), review(config, complete: false) ].each do |result|
      expect(result[:items].flat_map { |r| r[:commands] }).to be_empty
    end
  end

  it "retains historical conflicts from partial evidence without claiming current outages" do
    result = review(config, extra: { client_ip_conflicts: { status: "partial", records: [ { ip_address: "192.0.2.8", occurred_at: "09-24 15:45:43" } ], issues: [] } })
    item = result[:items].find { |r| r[:code] == "client_ip_conflict_history" }
    expect(item).to include(status: "investigate", commands: [])
    expect(item[:verify]).to include("display wlan statistics client-ip-conflict")
    expect(result[:items]).to include(include(code: "evidence_incomplete"))
  end

  it "does not turn an administratively down radio into an automatic enable script" do
    result = review(config, extra: { radios: { status: "complete", records: [ { ap_name: "ap1", radio_id: "3", admin_status: "Down" } ], issues: [] } })
    expect(result[:items].find { |r| r[:code] == "radios_admin_down" }).to include(status: "investigate", commands: [])
  end
  it "identifies a missing service template referenced under an AP radio without inventing its security" do
    body = "wlan ap ap1 model WA6530\n radio 1\n  service-template missing vlan 10\n#\n"
    result = review(body)
    expect(result[:items]).to include(include(code: "service_template_missing", status: "blocked", commands: []))
  end

  it "blocks injected template names instead of placing them in a command" do
    document = { "device" => { "platform" => "h3c_wireless" }, "snapshot" => { "dimensions" => { "configuration" => { "status" => "complete", "records" => [ { "service_templates" => [ { "name" => "lab\nreboot", "enabled" => true, "configuration" => { "cipher_suites" => %w[ccmp tkip], "security_ies" => %w[rsn wpa] } } ] } ] } } } }
    item = Wireless::Recommendations.new(document).call[:items].first
    expect(item).to include(status: "blocked", commands: [])
  end
end
