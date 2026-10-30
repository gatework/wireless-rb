# frozen_string_literal: true

require_relative "spec_helper"
require "wireless/recommendations"

RSpec.describe "Wireless AP operational status" do
  it "uses the same known states for parsing and recommendations" do
    %w[Run R running online normal nor up].each do |state|
      expect(Wireless::Fields.online_status(state)).to eq(:online)
    end
    %w[Idle fault offline down].each do |state|
      expect(Wireless::Fields.online_status(state)).to eq(:offline)
    end
    expect(Wireless::Fields.online_status("unrecognized")).to eq(:unknown)
    expect(Wireless::Fields.online_status(nil)).to eq(:unknown)
    rows = %w[online normal offline unrecognized].map { |state| { "name" => state, "operational_status" => state } }
    document = { "target" => { "platform" => "h3c" }, "snapshot" => {
      "observations" => { "access_points" => { "status" => "complete", "records" => rows, "issues" => [] } }
    } }
    items = Wireless::Recommendations.new(document).call.fetch(:items)
    offline = items.select { |item| item[:code] == "aps_not_running" }
    expect(offline.size).to eq(1)
    expect(offline.first[:evidence]).to eq([ { "name" => "offline", "operational_status" => "offline" } ])
  end
end
