# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Wireless::Terminal do
  it "recognizes command errors across supported newline formats without interpreting banners" do
    [ "\n", "\r\n", "\r" ].each do |newline|
      banner = [ "header login ^C", "Unrecognized command inside banner", "^C", "AP name: valid" ].join(newline)
      expect(described_class.unsupported?(banner)).to be(false)
      expect(described_class.unsupported?(banner + newline + "% Unrecognized command")).to be(true)
      expect(described_class.unsupported?("SSID: Unrecognized command" + newline)).to be(false)
    end
  end

  it "uses an explicit line separator even when the host changes its global separator" do
    previous = $/
    begin
      $/ = nil
      expect(described_class.unsupported?("header login ^C\nUnrecognized command\n^C\n")).to be(false)
      expect(described_class.unsupported?("AP name: valid\nUnrecognized command\n")).to be(true)
    ensure
      $/ = previous
    end
  end
end
