# frozen_string_literal: true

require_relative "spec_helper"
require "json"
require "digest"

RSpec.describe "Wireless evidence contracts" do
  let(:root) { File.join(__dir__, "fixtures/evidence") }
  let(:body) { File.binread(File.join(root, "huawei_ap_all.txt")) }

  it "keeps decoded Huawei facts while withholding transport completeness" do
    parser = Wireless::RuntimeParser.new
    complete = parser.parse(:access_points, body, platform: :huawei, complete: true)
    partial = parser.parse(:access_points, body, platform: :huawei, complete: false)
    expect(partial).to be_partial
    expect(partial.records).to eq(complete.records)
  end

  it "replays a vendor-derived nonempty AP table against independently annotated facts" do
    JSON.parse(File.read(File.join(root, "manifest.json"))).fetch("cases").each do |entry|
      input = File.binread(File.join(root, entry.fetch("file")))
      expect(Digest::SHA256.hexdigest(input)).to eq(entry.fetch("sha256"))
      actual = Wireless::RuntimeParser.new.parse(:access_points, input, platform: entry.fetch("platform"), complete: true)
      expect(JSON.parse(JSON.generate(actual.to_h.slice(:status, :records, :issues)))).to eq(entry.fetch("expected"))
    end
  end

  it "withholds completeness when Huawei table totals or required identity fields are lost" do
    [ body.sub("Total: 3\n", ""), body.sub("0200-0000-0001", "invalid-mac") ].each do |text|
      result = Wireless::RuntimeParser.new.parse(:access_points, text, platform: :huawei, complete: true)
      expect(result).not_to be_complete
    end
  end

  it "does not let a populated port hide an announced port without neighbor evidence" do
    text = "LLDP neighbor-information of port 1[GE1]:\nLLDP neighbor index: 1\nChassis ID: switch\nPort ID: GE2\n" \
      "LLDP neighbor-information of port 2[GE3]:\n"
    result = Wireless::NeighborParser.new.parse(text, ap_name: "AP-LAB", complete: true)
    expect(result).to be_partial
    expect(result.records.size).to eq(1)
    expect(result.issues).to include(include(code: :missing_port_evidence, local_interface: "GE3"))
  end

  it "uses registry aliases for connector compatibility instead of a second platform list" do
    registry = CtxParser::Registry.new(profiles: Wireless::PROFILES, aliases: { fixture_h3c: :h3c })
    stub_const("Wireless::ParserRegistry", registry)
    session = double("session", connected?: true)
    allow(session).to receive(:send_commands) do |commands|
      text = commands.first == "screen-length disable" ? "" : "Total number of APs : 0\n"
      double("receipt", success?: true, steps: [ Object.new ], output: text, value!: text)
    end
    [ [ :fixture_h3c, :h3c ], [ :h3c, :fixture_h3c ] ].each do |requested, actual|
      connector = double("connector", platform: actual)
      allow(connector).to receive(:open).and_yield(session)
      result = nil
      expect do
        result = Wireless::Collector.new.collect(connector: connector, target: {}, platform: requested, dimensions: [ :access_points ])
      end.not_to raise_error
      expect(result).to be_complete
    end
  end
end
