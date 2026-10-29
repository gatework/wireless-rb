# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_runner/document"

RSpec.describe "Wireless public observation protocol" do
  it "parses an explicit platform and command and exposes the shared snapshot contract" do
    parser = Wireless::RuntimeParser.new(platform: :h3c)
    observations = parser.parse_many([ :access_points ], "Total number of APs : 0\n", complete: true, command: "display wlan ap all verbose")
    expect(observations.fetch(:access_points)).to be_complete
    snapshot = Wireless::Snapshot.new(target: { host: "192.0.2.1" }, observations: observations, observed_at: Time.utc(2026, 10, 29))
    expect(snapshot.observation(:access_points)).to equal(observations.fetch(:access_points))
    expect(snapshot.observation(:configuration).status).to eq(:not_requested)
    expect { snapshot.observation(:invalid) }.to raise_error(ArgumentError)
    document = CtxRunner::Document.call(snapshot)
    expect(document.fetch("observations").fetch("access_points").fetch("status")).to eq("complete")
    expect(document).not_to have_key("dimensions")
  end
end
