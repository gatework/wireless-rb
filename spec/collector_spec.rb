# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Wireless::Collector do
  let(:target) { { key: "fixture:controller", host: +"192.0.2.10" } }
  let(:connector) { double("Connector", platform: :h3c_wireless) }
  let(:session) { double("CLI session", connected?: true) }
  let(:collector) { described_class.new }
  let(:outputs) do
    { "screen-length disable" => "", "display wlan ap all verbose" => "Total number of APs : 0\n",
      "display wlan client verbose" => "Total number of clients : 0\n" }
  end

  before do
    allow(connector).to receive(:open).and_yield(session)
    allow(session).to receive(:send_commands) do |commands|
      expect(commands.size).to eq(1)
      body = outputs.fetch(commands.first)
      raise body if body.is_a?(Exception)

      double("Command receipt", output: "#{commands.first}\n#{body}<WLC>", success?: true, steps: [ Object.new ], value!: body)
    end
  end

  # 使用与 gem 调用方一致的注入身份和平台契约。
  def collect(*dimensions, **options)
    collector.collect(connector: connector, target: target, platform: :h3c, dimensions: dimensions, **options)
  end

  it "collects shared AP and radio output once through the supplied connector" do
    expect(connector).to receive(:open).once.and_yield(session)
    result = collect(:access_points, :radios)

    expect(result).to be_complete
    expect(result.target).to eq(target)
    expect(result.dimension(:access_points)).to be_complete
    expect(result.dimension(:radios)).to be_complete
    expect(session).to have_received(:send_commands).with([ "display wlan ap all verbose" ]).once
    expect(result.dimension(:clients).status).to eq(:not_requested)
  end

  it "continues independent client collection after the AP command fails" do
    outputs["display wlan ap all verbose"] = IOError.new("private transport detail")
    result = collect(:access_points, :clients)

    expect(result.dimension(:access_points).status).to eq(:failed)
    expect(result.dimension(:clients)).to be_complete
    expect(result.dimension(:collection)).to be_partial
    expect(result.dimension(:access_points).issues.inspect).not_to include("private transport detail")
  end

  it "does not resolve nested AP credentials when LLDP was not requested" do
    credentials = double("Lazy AP credentials")
    expect(credentials).not_to receive(:call)

    expect(collect(:access_points, ap_connection: credentials)).to be_complete
  end

  it "reports missing AP credentials while retaining the completed controller inventory" do
    result = collect(:lldp)

    expect(result.dimension(:access_points)).to be_complete
    expect(result.dimension(:lldp).issues).to eq([ { code: :ap_credentials_required } ])
    expect(result.dimension(:collection)).to be_partial
  end

  it "retains acquired facts when closing the injected session fails" do
    allow(connector).to receive(:open) do |&operation|
      operation.call(session)
      raise IOError, "private close diagnostic"
    end
    result = collect(:access_points)

    expect(result.dimension(:access_points)).to be_complete
    expect(result.dimension(:collection).issues).to eq([ { code: :session_close_failed } ])
  end

  it "rejects invalid targets, selections and mismatched platforms without connecting" do
    expect(connector).not_to receive(:open)
    expect { collector.collect(connector: connector, target: nil, platform: :h3c) }.to raise_error(ArgumentError)
    [ [], [ :clients, :clients ], [ :unknown ] ].each do |dimensions|
      expect { collect(*dimensions) }.to raise_error(ArgumentError)
    end
    allow(connector).to receive(:platform).and_return(:cisco_nxos)
    expect { collect(:access_points) }.to raise_error(ArgumentError, "Wireless platform differs from the device connector")
  end
end
