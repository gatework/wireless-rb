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
end
