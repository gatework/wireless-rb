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

  it "keeps shared configuration projections partial without poisoning unrelated collection" do
    outputs["display current-configuration"] = "sysname WLC\nwlan service-template office\n ssid Office\n#\n--More--\nreturn\n"
    result = collect(:configuration, :ap_groups, :service_templates, :clients)

    %i[configuration ap_groups service_templates collection].each do |dimension|
      expect(result.dimension(dimension)).to be_partial
    end
    expect(result.dimension(:service_templates).records.first[:ssid]).to eq("Office")
    expect(result.dimension(:clients)).to be_complete
    expect(session).to have_received(:send_commands).with([ "display current-configuration" ]).once
  end

  it "does not resolve nested AP credentials when LLDP was not requested" do
    credentials = double("Lazy AP credentials")
    expect(credentials).not_to receive(:call)

    expect(collect(:access_points, ap_connection: credentials)).to be_complete
  end

  it "requires an explicit AP session factory while retaining the controller inventory" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    result = collect(:lldp)

    expect(result.dimension(:access_points)).to be_complete
    expect(result.dimension(:lldp).issues).to eq([ { code: :ap_session_required } ])
    expect(result.dimension(:collection)).to be_partial
  end

  it "does not resolve AP credentials when no AP transport was injected" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    credentials = double("Lazy AP credentials")
    expect(credentials).not_to receive(:call)
    expect(collect(:lldp, ap_connection: credentials).dimension(:lldp).issues).to eq([ { code: :ap_session_required } ])
  end

  it "collects AP neighbors through a host-supplied reader without requiring a password" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    ap_reader = double("AP reader")
    now = Time.utc(2026, 10, 17)
    capture = CtxDriver::Capture.new(command: "display lldp neighbor-information verbose",
      body: "No LLDP neighbors\n", started_at: now, completed_at: now,
      evidence: [ { sha256: "synthetic", bytes: 18 } ])
    expect(ap_reader).to receive(:read).with(access_point: include(name: "AP-LAB")).and_return(result: capture)
    factory = double("AP session factory")
    expect(factory).to receive(:call).with(controller: session).once.and_return(ap_reader)
    reader = described_class.new(ap_session: factory)
    result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])
    expect(result.dimension(:lldp)).to be_complete
    expect(result.dimension(:lldp).evidence.first).to include(ap_name: "AP-LAB", attempted: true, status: :complete)
  end

  it "isolates an AP transport failure from controller observations and other APs" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 2\nAP name : AP-1\nAP ID : 1\nState : Run\nAP name : AP-2\nAP ID : 2\nState : Run\n"
    ap_reader = double("AP reader")
    expect(ap_reader).to receive(:read).with(access_point: include(name: "AP-1")).and_raise(IOError, "private endpoint")
    expect(ap_reader).to receive(:read).with(access_point: include(name: "AP-2")).and_return(error: :ap_not_online, skipped: true)
    reader = described_class.new(ap_session: ->(controller:) { ap_reader })
    result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp, :clients ])
    expect(result.dimension(:clients)).to be_complete
    expect(result.dimension(:access_points)).to be_complete
    expect(result.dimension(:lldp).status).to eq(:failed)
    expect(result.dimension(:lldp).issues).to include(include(ap_name: "AP-1"), include(code: :ap_not_online, ap_name: "AP-2"))
    expect(result.dimension(:lldp).issues.inspect).not_to include("private endpoint")
  end

  it "binds AP evidence to the selected AP and LLDP command while retaining capture metadata" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    now = Time.utc(2026, 10, 17)
    command = Wireless::H3c::Profile::COMMANDS.fetch(:lldp)
    capture = CtxDriver::Capture.new(command: command, body: "No LLDP neighbors\n", started_at: now, completed_at: now,
      evidence: [ { sha256: "synthetic", observed_at: now.iso8601, kind: :other, ap_name: "OTHER-AP",
        command: "unrelated-command", attempted: false, status: :failed, neighbor_count: 99 } ])
    ap_reader = double("AP reader", read: { result: capture })
    reader = described_class.new(ap_session: ->(controller:) { ap_reader })

    result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])

    expect(result.dimension(:lldp)).to be_complete
    expect(result.dimension(:lldp).evidence).to eq([ { sha256: "synthetic", observed_at: now.iso8601,
      kind: :ap_lldp_result, ap_name: "AP-LAB", command: command, attempted: true, status: :complete, neighbor_count: 0 } ])
  end

  it "rejects wrong-command and skipped successful AP captures without losing controller facts" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    now = Time.utc(2026, 10, 17)
    [ { command: "display unrelated", skipped: false },
      { command: Wireless::H3c::Profile::COMMANDS.fetch(:lldp), skipped: true } ].each do |attributes|
      capture = CtxDriver::Capture.new(command: attributes[:command], body: "No LLDP neighbors\n",
        started_at: now, completed_at: now)
      ap_reader = double("AP reader", read: { result: capture, skipped: attributes[:skipped] })
      reader = described_class.new(ap_session: ->(controller:) { ap_reader })

      result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])

      expect(result.dimension(:access_points)).to be_complete
      expect(result.dimension(:lldp).status).to eq(:failed)
      expect(result.dimension(:lldp).issues).to include(include(code: :invalid_command_result, stage: :response, ap_name: "AP-LAB"))
      expect(result.dimension(:lldp).evidence.first).to include(ap_name: "AP-LAB", status: :failed, neighbor_count: 0)
    end
  end

  it "does not construct an AP reader or resolve credentials for an empty complete inventory" do
    factory, credentials = double("AP factory"), double("AP credentials")
    expect(factory).not_to receive(:call)
    expect(credentials).not_to receive(:call)
    result = described_class.new(ap_session: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp ], ap_connection: credentials)
    expect(result.dimension(:lldp)).to be_complete
    expect(result.dimension(:lldp).records).to be_empty
  end

  it "does not require an AP transport when the controller reports no APs" do
    result = collect(:lldp)
    expect(result).to be_complete
    expect(result.dimension(:lldp)).to be_complete
  end

  it "keeps AP setup failures separate from controller connection failures" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    factory = ->(controller:) { raise IOError, "private adapter details" }
    result = described_class.new(ap_session: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp, :clients ])
    expect(result.dimension(:clients)).to be_complete
    expect(result.dimension(:access_points)).to be_complete
    expect(result.dimension(:lldp).issues).to include(include(code: :ap_session_setup_failed, stage: :ap_setup))
    expect(result.dimension(:collection).status).to eq(:partial)
    expect(result.dimension(:lldp).issues.inspect).not_to include("private adapter details")
  end

  it "snapshots target identity before opening an external session" do
    allow(connector).to receive(:open) do |&operation|
      target[:host].replace("192.0.2.99")
      operation.call(session)
    end
    result = collect(:access_points)
    expect(result.target[:host]).to eq("192.0.2.10")
    expect(target[:host]).to eq("192.0.2.99")
  end

  it "keeps platform and model selection stable across connector callbacks" do
    platform, model = +"h3c", +"WX-LAB"
    allow(connector).to receive(:open) do |&operation|
      platform.replace("huawei")
      model.replace("changed-model")
      operation.call(session)
    end
    expect(Wireless::RuntimeParser).to receive(:new).with(model: "WX-LAB").and_call_original

    result = collector.collect(connector: connector, target: target, platform: platform,
      model: model, dimensions: [ :access_points ])

    expect(result.dimension(:access_points)).to be_complete
    expect(session).to have_received(:send_commands).with([ "screen-length disable" ])
    expect(platform).to eq("huawei")
    expect(model).to eq("changed-model")
  end

  it "keeps the borrowed controller authoritative over AP credential options" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    ap_reader = double("AP reader", read: { error: :ap_not_online, skipped: true })
    factory = double("AP factory")
    expect(factory).to receive(:call).with(controller: session, password: "example").and_return(ap_reader)

    result = described_class.new(ap_session: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp ], ap_connection: { controller: Object.new, password: "example" })

    expect(result.dimension(:access_points)).to be_complete
    expect(result.dimension(:lldp).issues).to include(code: :ap_not_online, ap_name: "AP-LAB")
  end

  it "keeps AP selection independent of mutations during adapter construction" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 2\nAP name : AP-1\nAP ID : 1\nState : Run\nAP name : AP-2\nAP ID : 2\nState : Run\n"
    selected = [ +"AP-1" ]
    ap_reader = double("AP reader")
    expect(ap_reader).to receive(:read).with(access_point: include(name: "AP-1")).and_return(error: :ap_not_online, skipped: true)
    factory = lambda do |controller:|
      selected.first.replace("AP-2")
      ap_reader
    end
    result = described_class.new(ap_session: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp ], ap_names: selected)
    expect(result.dimension(:lldp).evidence.map { |entry| entry[:ap_name] }).to eq([ "AP-1" ])
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
