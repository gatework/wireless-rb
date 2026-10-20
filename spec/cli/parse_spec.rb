# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli/parse"
require "stringio"

RSpec.describe Wireless::CLI::Parse do
  def parse(body, *args)
    @out, @error = StringIO.new, StringIO.new
    described_class.new(input: StringIO.new(body), out: @out, error: @error).run(args)
  end

  it "keeps input incomplete unless explicitly declared complete" do
    expect(parse("sysname WLC\nreturn\n", "--json")).to eq(1)
    expect(JSON.parse(@out.string)).to include("status" => "partial")
    expect(parse("sysname WLC\nreturn\n", "--complete")).to eq(0)
    expect(@out.string).not_to include("sysname WLC")
  end

  it "uses the selected Huawei parser and reports unsupported dimensions" do
    body = "ID MAC Name Group IP Type State STA Uptime\nTotal: 0\n"
    expect(parse(body, "--platform", "huawei", "--dimension", "access_points", "--complete", "--json")).to eq(0)
    expect(JSON.parse(@out.string)).to include("status" => "complete", "records" => [])
    expect(parse("", "--platform", "huawei", "--dimension", "configuration", "--complete", "--json")).to eq(1)
    expect(JSON.parse(@out.string)).to include("status" => "unsupported")
  end

  it "requires AP identity for LLDP and accepts a complete empty neighbor result" do
    expect(parse("No LLDP neighbors\n", "--dimension", "lldp", "--complete")).to eq(2)
    expect(parse("No LLDP neighbors\n", "--dimension", "lldp", "--ap-name", "AP-LAB", "--complete", "--json")).to eq(0)
    expect(JSON.parse(@out.string)).to include("status" => "complete", "records" => [])
  end

  it "rejects invalid dimensions, platforms and inaccessible files without disclosing contents" do
    [ [ "--dimension", "unknown" ], [ "--platform", "unknown" ], [ "--file", "/missing/fixture.txt" ] ].each do |args|
      expect(parse("private-fixture", *args)).to eq(2)
      expect(@out.string + @error.string).not_to include("private-fixture")
    end
  end
end
