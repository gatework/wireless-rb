# frozen_string_literal: true

require_relative "spec_helper"
require "wireless/coverage"

RSpec.describe Wireless::Coverage do
  let(:now) { Time.utc(2026, 10, 16, 8) }

  def coverage(at:, projection: {})
    described_class.new(observations: { "access_points" => { "latest" => { "status" => "complete", "observed_at" => at } } },
      projection: projection, dimensions: [ :access_points ], now: now, stale_after: 3600).to_h
  end

  it "requires a valid fresh sample time before complete evidence can support health" do
    expect(coverage(at: now.iso8601).fetch("state")).to eq("complete")
    [ nil, "invalid", (now + 60).iso8601 ].each do |at|
      expect(coverage(at: at).fetch("state")).to eq("unknown")
    end
    expect(coverage(at: (now - 3601).iso8601).fetch("state")).to eq("stale")
  end

  it "exposes blocked inventory application separately from complete collected facts" do
    result = coverage(at: now.iso8601, projection: { "access_points" => { "status" => "blocked", "observed_at" => now.iso8601 } })
    expect(result.fetch("state")).to eq("unknown")
    expect(result.dig("dimensions", "access_points")).to include("status" => "complete", "reason" => "projection_incomplete")
  end

  it "does not attribute an old projection result to a newer collection" do
    result = coverage(at: now.iso8601,
      projection: { "access_points" => { "status" => "blocked", "observed_at" => (now - 60).iso8601 } })
    expect(result.dig("dimensions", "access_points")).to include("state" => "unknown", "reason" => "projection_time_unconfirmed")
  end
  it "requires explicit successful projection metadata when a dimension is present" do
    [ "failed", "unsupported", "pending", nil ].each do |status|
      result = coverage(at: now.iso8601,
        projection: { "access_points" => { "status" => status, "observed_at" => now.iso8601 } })
      expect(result.dig("dimensions", "access_points")).to include("state" => "unknown", "reason" => "projection_incomplete")
    end
    expect(coverage(at: now.iso8601, projection: { "access_points" => {} }).fetch("state")).to eq("unknown")
    expect(coverage(at: now.iso8601,
      projection: { "access_points" => { "status" => "complete", "observed_at" => now.iso8601 } }).fetch("state")).to eq("complete")
  end
end
