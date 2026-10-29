# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "H3C live output consistency" do
  let(:parser) { Wireless::RuntimeParser.new(platform: :h3c) }

  it "keeps repeated indistinguishable conflict events partial while preserving later occurrences" do
    text = File.read(File.expand_path("../fixtures/wireless/client_ip_conflicts_repeated.txt", __dir__))
    result = parser.parse(:client_ip_conflicts, text, complete: true)

    expect(result).to be_partial
    expect(result.issues).to eq([ { code: :duplicate_identity } ])
    expect(result.records.size).to eq(2)
    expect(result.records.map { |record| record.fetch(:occurred_at) }).to eq([ "10-16 18:47:45", "10-16 18:47:46" ])
  end

  it "preserves a fully decoded session when the initial device total exceeds returned blocks" do
    text = File.read(File.expand_path("../fixtures/wireless/dot1x_changing_total.txt", __dir__))
    result = parser.parse(:dot1x_connections, text, complete: true)

    expect(result).to be_partial
    expect(result.issues).to eq([ { code: :count_mismatch, expected: 2, parsed: 1 } ])
    expect(only_record(result.records)).to include(mac_address: "02:00:00:00:00:01", online_seconds: 2876)
    expect(parser.parse(:dot1x_connections, text.sub("Total connections: 2", "Total connections: 1"), complete: true)).to be_complete
  end
end
