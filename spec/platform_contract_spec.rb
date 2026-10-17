# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Wireless platform contracts" do
  it "rejects malformed caller arguments before examining device output" do
    parser = Wireless::RuntimeParser.new
    %i[h3c huawei].each do |platform|
      expect { parser.parse(:access_points, "Total: 0\n", platform: platform, complete: "false") }.to raise_error(ArgumentError)
      expect { parser.parse_many([ :clients, :clients ], "", platform: platform) }.to raise_error(ArgumentError)
    end
    expect { parser.parse(:clients, "", platform: :unknown) }.to raise_error(ArgumentError)
    expect { Wireless::Configuration.new.parse("sysname LAB\n", complete: "true") }.to raise_error(ArgumentError)
  end

  it "uses the Huawei command profile for complete and partial evidence" do
    profile = Wireless::ParserRegistry.fetch(:huawei)
    expect(profile.command(:access_points)).to eq("display ap all")
    text = "ID MAC Name Group IP Type State STA Uptime\nTotal: 0\n"
    expect(profile.parse(:access_points, text, complete: true)).to be_complete
    expect(profile.parse(:access_points, text, complete: false)).not_to be_complete
    expect { profile.parse(:access_points, text, complete: "false") }.to raise_error(ArgumentError)
  end

  it "collects Huawei queries through its profile and preserves unsupported dimensions" do
    session = double("Huawei session", connected?: true)
    connector = double("Huawei connector", platform: :huawei)
    allow(connector).to receive(:open).and_yield(session)
    commands = []
    allow(session).to receive(:send_commands) do |queries|
      commands.concat(queries)
      body = queries.first == "display ap all" ? "ID MAC Name Group IP Type State STA Uptime\nTotal: 0\n" : ""
      double("Receipt", output: body, success?: true, steps: [ Object.new ], value!: body)
    end
    result = Wireless::Collector.new.collect(connector: connector, target: { host: "192.0.2.1" }, platform: :huawei,
      dimensions: [ :access_points, :radios ])
    expect(commands).to eq([ "screen-length 0 temporary", "display ap all" ])
    expect(result.dimension(:access_points)).to be_complete
    expect(result.dimension(:radios).status).to eq(:unsupported)
  end

  it "keeps invalid encoded device bodies as failed observations" do
    %i[h3c huawei].each do |platform|
      result = Wireless::RuntimeParser.new.parse(:access_points, "\xff".b, platform: platform, complete: true)
      expect(result.status).to eq(:failed)
    end
  end
end
