# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Wireless parsing in an embedding Ruby process" do
  it "uses CLI newlines independently of the host input record separator" do
    parser = Wireless::RuntimeParser.new(platform: :h3c)
    samples = [
      [ :access_points, "AP name: AP\nAP ID: 1\nTotal APs: 1\n", :h3c ],
      [ :clients, "MAC address: 0200-0000-0001\nTotal clients: 1\n", :h3c ],
      [ :blocked_clients, "MAC address Reason\n0200-0000-0001 Failure\nTotal: 1\n", :h3c ],
      [ :client_ip_conflicts, File.read(File.expand_path("fixtures/wireless/client_ip_conflicts.txt", __dir__)), :h3c ],
      [ :ap_models, File.read(File.expand_path("fixtures/wireless/ap_models.txt", __dir__)), :h3c ],
      [ :access_points, "ID MAC Name Group IP Type State STA Uptime\n0 0200-0000-0001 AP LAB 192.0.2.1 TEST nor 0 001:02:03:04\nTotal: 1\n", :huawei ]
    ]
    baseline = samples.map { |name, body, platform| Wireless::RuntimeParser.new(platform: platform).parse(name, body, complete: true).to_h }
    expect(baseline).to all(include(status: :complete))
    previous_separator = $/
    [ nil, "|", "" ].each do |separator|
      $/ = separator
      samples.each_with_index do |(name, body, platform), index|
        expect(Wireless::RuntimeParser.new(platform: platform).parse(name, body, complete: true).to_h).to eq(baseline[index])
      end
    end
  ensure
    $/ = previous_separator
  end

  it "keeps neighbor field line numbers independent of the host record separator" do
    parser = Wireless::NeighborParser.new
    body = "LLDP neighbor-information of port 1[GE1]:\nLLDP neighbor index: 1\nChassis ID: switch\nPort ID: GE2\nTotal neighbors: 1\n"
    baseline = parser.parse(body, ap_name: "AP", complete: true).to_h
    expect(baseline).to include(status: :complete)
    previous_separator = $/
    $/ = nil
    expect(parser.parse(body, ap_name: "AP", complete: true).to_h).to eq(baseline)
  ensure
    $/ = previous_separator
  end
end
