# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "H3C AP radio detail scopes" do
  let(:parser) { Wireless::RuntimeParser.new }

  # 字段层次依据 H3C AP management 命令参考，值为合成数据。
  let(:output) do
    <<~CLI
      Total number of APs: 1
      AP name: AP-A
      Radio 1:
          Base BSSID: 0200-0000-0001
          State: Up
          Channel band-width: 80MHz
          Operational VHT-MCS Set:
              Mandatory: Not configured
              Supported: NSS1 0,1,2,3,4,5,6,7,8,9
          Operational HT MCS Set:
              Mandatory: Not configured
              Supported: 0,1,2,3,4,5,6,7
          Operational HE-MCS Set:
              Supported: NSS1 0,1,2,3,4,5,6,7,8,9,10,11
          Operational rate:
              Mandatory: 6, 12, 24 Mbps
              Supported: 9, 18, 36, 48, 54 Mbps
    CLI
  end

  it "keeps repeated labels distinct across documented radio subsections" do
    result = parser.parse(:radios, output, complete: true)
    expect(result).to be_complete
    radio = result.records.first
    expect(radio).to include(channel_width: 80, admin_status: "Up")
    expect(radio[:details]).to include(base_bssid: "0200-0000-0001")
    expect(radio[:details][:vht_mcs]).to include(supported: "NSS1 0,1,2,3,4,5,6,7,8,9", mandatory: nil)
    expect(radio[:details][:ht_mcs]).to include(supported: "0,1,2,3,4,5,6,7", mandatory: nil)
    expect(radio[:details][:he_mcs]).to include(supported: "NSS1 0,1,2,3,4,5,6,7,8,9,10,11")
    expect(radio[:details][:operational_rates]).to include(mandatory: "6, 12, 24 Mbps", supported: "9, 18, 36, 48, 54 Mbps")
  end

  it "removes conflicting fields only within their own subsection" do
    text = output.sub("    Operational HT MCS Set:", "        Supported: changed\n        Supported: NSS1 0,1,2,3,4,5,6,7,8,9\n    Operational HT MCS Set:")
    result = parser.parse(:radios, text, complete: true)
    expect(result).to be_partial
    details = result.records.first[:details]
    expect(details[:vht_mcs]).not_to have_key(:supported)
    expect(details[:ht_mcs][:supported]).to eq("0,1,2,3,4,5,6,7")
    expect(details[:operational_rates][:supported]).to eq("9, 18, 36, 48, 54 Mbps")
  end

  it "ends a subsection at a sibling field and at the next radio or AP" do
    text = output + "    Antenna type: internal\n    Supported: sibling\nRadio 2:\n    Supported: radio-two\n" \
      "AP name: AP-B\nRadio 1:\n    Supported: ap-two\n"
    result = parser.parse(:radios, text.sub("APs: 1", "APs: 2"), complete: true)
    expect(result).to be_complete
    first, second, third = result.records
    expect(first[:details]).to include(antenna_type: "internal", supported: "sibling")
    expect(first[:details][:operational_rates][:supported]).to eq("9, 18, 36, 48, 54 Mbps")
    expect(second[:details]).to eq(supported: "radio-two")
    expect(third[:details]).to eq(supported: "ap-two")
  end
  it "does not use an AP count as evidence of an empty radio inventory" do
    text = "Total APs: 1\nAP name: AP-A\nState: Run\n"
    observations = parser.parse_many(%i[access_points radios], text, complete: true)
    expect(observations[:access_points]).to be_complete
    expect(observations[:radios]).not_to be_complete
    expect(observations[:radios].issues).to include(include(code: :missing_radio_evidence, ap_name: "AP-A"))
    observations = parser.parse_many(%i[access_points radios], "Total APs: 0\n", complete: true)
    expect(observations.values).to all(be_complete)
  end

  it "checks radio coverage for every AP without contaminating the AP view" do
    text = output.sub("APs: 1", "APs: 2") + "AP name: AP-B\nState: Idle\n"
    observations = parser.parse_many(%i[access_points radios], text, complete: true)
    expect(observations[:access_points]).to be_complete
    expect(observations[:radios]).to be_partial
    expect(observations[:radios].records.size).to eq(1)
    expect(observations[:radios].issues).to include(code: :missing_radio_evidence, ap_name: "AP-B")
  end
  it "keeps operating width priority for every channel bandwidth alias" do
    [ "Channel bandwidth", "Channel band-width" ].each do |label|
      [ [ "Operating bandwidth: 40MHz", "#{label}: 80MHz" ],
        [ "#{label}: 80MHz", "Operating bandwidth: 40MHz" ] ].each do |fields|
        text = "Total APs: 1\nAP name: AP-A\nRadio 1:\n" + fields.join("\n") + "\n"
        result = parser.parse(:radios, text, complete: true)
        expect(result).to be_complete
        expect(result.records.first[:channel_width]).to eq(40)
      end
    end
  end
end
