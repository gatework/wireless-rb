# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "H3C conflict and AP model observations" do
  let(:parser) { Wireless::RuntimeParser.new(platform: :h3c) }
  let(:conflicts) { File.read(File.expand_path("../fixtures/wireless/client_ip_conflicts.txt", __dir__)) }
  let(:models) { File.read(File.expand_path("../fixtures/wireless/ap_models.txt", __dir__)) }

  it "parses IPv4 and IPv6 events with both client identities and the original device time" do
    result = parser.parse(:client_ip_conflicts, conflicts, complete: true)
    expect(result).to be_complete
    expect(result.records.first).to eq(ip_address: "192.0.2.1", new_mac_address: "02:00:00:00:00:01",
      new_ap_id: "7", old_mac_address: "02:00:00:00:00:02", old_ap_id: "8", occurred_at: "03-22 10:00:00")
    expect(result.records.last[:ip_address]).to eq("2001:db8::1")
  end

  it "recognizes a completed empty conflict table but not absent or truncated evidence" do
    expect(parser.parse(:client_ip_conflicts, conflicts.lines.first, complete: true)).to be_complete
    expect(parser.parse(:client_ip_conflicts, "", complete: true).status).to eq(:failed)
    expect(parser.parse(:client_ip_conflicts, conflicts)).to be_partial
    expect(parser.parse(:client_ip_conflicts, conflicts.lines.first).status).to eq(:failed)
  end

  it "keeps valid conflict rows when another row has invalid fields or is unrecognized" do
    [ conflicts.sub("192.0.2.1", "999.0.2.1"), conflicts.sub("03-22", "02-30"),
      conflicts.sub("0200-0000-0001", "invalid"), conflicts + "unknown output\n" ].each do |text|
      expect(parser.parse(:client_ip_conflicts, text, complete: true)).to be_partial
    end
    duplicated = parser.parse(:client_ip_conflicts, conflicts + conflicts.lines.last, complete: true)
    expect(duplicated).to be_partial
    expect(duplicated.records.size).to eq(2)
  end

  it "parses multiple model capability blocks and preserves hardware version spelling" do
    result = parser.parse(:ap_models, models + models.gsub("WA6520", "WA6530"), complete: true)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:model] }).to eq(%w[WA6520 WA6530])
    model = result.records.first
    expect(model).to include(vendor_name: "H3C", vendor_id: 25506, license_weight: 100, license_type: 1, radio_count: 2, type: "COMMON")
    expect(model[:radios].first).to include(radio_id: "1", modes: %w[802.11a 802.11an 802.11ac 802.11ax], bss_count: 8)
    expect(model[:versions].last).to eq(hardware_version: "Ver.B", software_version: "R2595P28",
      default_software_version: "R2595P28", image_name: "wa6500a.ipe")
  end

  it "does not mark incomplete, duplicated or unrecognized model capabilities complete" do
    [ models.sub("Radio count : 2", "Radio count : 3"), models.sub("BSS count : 8", "BSS count : unknown"),
      models.sub("Radio 2:", "Radio 1:"), models.lines[0...-1].join, models + models, models + "Unknown secret : hidden\n",
      "AP model : WA6520\n" ].each do |text|
      expect(parser.parse(:ap_models, text, complete: true)).to be_partial
    end
    expect(parser.parse(:ap_models, models)).to be_partial
    expect(parser.parse(:ap_models, "", complete: true).status).to eq(:failed)
    expect(parser.parse(:ap_models, "Total number of AP models: 0\n", complete: true)).to be_complete
  end

  it "reports unsupported commands without producing records" do
    %i[ap_models client_ip_conflicts].each do |name|
      result = parser.parse(name, "% Unrecognized command found at '^' position.\n", complete: true)
      expect(result.status).to eq(:unsupported)
      expect(result.records).to be_empty
      expect(Wireless::RuntimeParser.new(platform: "huawei").parse(name, "", complete: true).status).to eq(:unsupported)
    end
  end

  [
    [ "Vendor ID : 25506", "Vendor ID : 25507", [ :vendor_id ] ],
    [ "BSS count : 8", "BSS count : 16", [ :radios, 0, :bss_count ] ],
    [ "Software Version : R2595P28", "Software Version : R2595P29", [ :versions, 0, :software_version ] ]
  ].each do |original, conflicting, path|
    it "accepts equivalent repeated #{path.last} model fields" do
      result = parser.parse(:ap_models, models.sub(original, "#{original}\n#{original}"), complete: true)
      expect(result).to be_complete
      expect(result.records).to eq(parser.parse(:ap_models, models, complete: true).records)
    end

    it "removes conflicting #{path.last} model fields without reviving earlier values" do
      result = parser.parse(:ap_models, models.sub(original, "#{original}\n#{conflicting}\n#{original}"), complete: true)
      expect(result).to be_partial
      expect(result.records.first.dig(*path)).to be_nil
      expect(result.issues).to include(hash_including(code: :conflicting_field))
    end
  end
end
