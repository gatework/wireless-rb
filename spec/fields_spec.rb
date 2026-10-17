# frozen_string_literal: true

require_relative "spec_helper"
require "wireless/fields"

RSpec.describe Wireless::Fields do
  it "makes measurement units explicit for normalized wireless facts" do
    expect(described_class.duration_seconds("1d 2h 3m 4s")).to eq(93_784)
    expect(described_class.rates_mbps("12000/24000 Kbps")).to eq([ 12.0, 24.0 ])
    expect(described_class.channel_width_mhz("80MHz")).to eq(80)
    expect(described_class.duration_seconds(nil)).to be_nil
    expect(described_class.rates_mbps(nil)).to eq([ nil, nil ])
    expect(described_class.channel_width_mhz("unknown")).to be_nil
  end

  it "requires unambiguous band evidence rather than guessing from overlapping channel numbers" do
    [ 1, 5, 149, 233 ].each do |channel|
      expect(described_class.frequency_band(channel.to_s)).to be_nil
      expect(described_class.frequency_band("802.11ax")).to be_nil
    end
    expect(described_class.frequency_band("802.11ax 6GHz")).to eq("6GHz")
    expect(described_class.frequency_band("802.11b/g/n")).to eq("2.4GHz")
    expect(described_class.frequency_band("802.11ac 5GHz")).to eq("5GHz")
    expect(described_class.frequency_band("5GHz / 6GHz")).to be_nil
    expect(described_class.frequency_band("16GHz")).to be_nil
    expect(described_class.frequency_band("24GHz")).to be_nil
  end

  it "rejects numeric overflow before it becomes a wireless measurement" do
    oversized = "9" * 400

    expect { described_class.number(oversized, unit: "dBm") }.to raise_error(ArgumentError, "Invalid wireless number")
    expect { described_class.number("-#{oversized} dBm", unit: "dBm") }.to raise_error(ArgumentError, "Invalid wireless number")
    expect { described_class.rates_mbps("#{oversized}/1 Mbps") }.to raise_error(ArgumentError, "Invalid wireless rates")
    expect { described_class.rates_mbps("1/#{'9' * 305} Tbps") }.to raise_error(ArgumentError, "Invalid wireless rates")
  end

  it "isolates overflowing client measurements without losing the client identity" do
    oversized = "9" * 400
    { "RSSI" => oversized, "Rx/Tx rate" => "#{oversized}/1 Mbps" }.each do |field, value|
      text = "Total number of clients : 1\nMAC address : 0200-0000-0101\n#{field} : #{value}\n"
      observation = Wireless::RuntimeParser.new.parse(:clients, text, complete: true)

      expect(observation).to be_partial
      expect(only_record(observation.records)).to eq(client_mac: "02:00:00:00:01:01")
      expect(observation.issues).to include(code: :invalid_field, line: 3)
    end
  end
end
