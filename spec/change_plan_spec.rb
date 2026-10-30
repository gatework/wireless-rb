# frozen_string_literal: true

require_relative "spec_helper"
require "wireless/change_plan"

RSpec.describe Wireless::ChangePlan do
  let(:value) { { "kind" => "wireless_security", "name" => "corp", "enabled" => true, "cipher_suites" => %w[ccmp tkip], "security_ies" => %w[rsn wpa] } }
  let(:before) { { "service_templates" => [ { "name" => "corp", "ssid" => "staff", "enabled" => true, "configuration" => value.slice("cipher_suites", "security_ies") } ], "access_points" => { "AP1" => {} } } }
  let(:after) do
    copy = Marshal.load(Marshal.dump(before))
    copy["service_templates"][0]["configuration"] = { "cipher_suites" => [ "ccmp" ], "security_ies" => [ "rsn" ] }
    copy
  end

  it "accepts only the declared security delta and preserves unrelated configuration" do
    change = described_class.build(value)
    expect(change.satisfied?(after, before: before)).to be_truthy
    after["service_templates"][0]["ssid"] = "guest"
    expect(change.satisfied?(after, before: before)).to be_falsey
  end

  it "rejects lost APs and ambiguous template identities" do
    change = described_class.build(value)
    expect(change.satisfied?(after.merge("access_points" => {}), before: before)).to be_falsey
    before["service_templates"] *= 2
    expect(change.eligible?(before)).to be_falsey
    expect(change.satisfied?(after, before: before)).to be_falsey
  end

  it "uses one immutable template index for multiple candidates and retains ambiguity" do
    index = Wireless::ConfigurationIndex.new(before)
    change = described_class.candidate(value, config: index)
    expect(change.to_h).to eq(value)
    before["service_templates"].clear
    expect(change.eligible?(index)).to be(true)
    ambiguous = index.configuration.merge("service_templates" => index.configuration["service_templates"] * 2)
    expect(described_class.candidate(value, config: Wireless::ConfigurationIndex.new(ambiguous))).to be_nil
  end

  it "rejects unknown fields and duplicated security values before creating commands" do
    [ value.merge("commands" => [ "reboot" ]), value.merge("cipher_suites" => %w[ccmp tkip tkip]) ].each do |invalid|
      expect { described_class.build(invalid) }.to raise_error(ArgumentError)
      expect(described_class.candidate(invalid, config: before)).to be_nil
    end
  end
end
