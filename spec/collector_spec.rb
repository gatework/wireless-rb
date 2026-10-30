# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Wireless::Collector do
  let(:target) { { id: "fixture:controller", host: +"192.0.2.10" } }
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

      double("Command receipt", output: "#{commands.first}\n#{body}<WLC>", success?: true, steps: [ { command: commands.first } ], value!: body)
    end
  end

  # 使用与 gem 调用方一致的注入身份和平台契约。
  def collect(*dimensions, **options)
    collector.collect(connector: connector, target: target, platform: :h3c, dimensions: dimensions, **options)
  end

  it "borrows a session without opening or closing it and shares the normal query plan" do
    expect(connector).not_to receive(:open)
    expect(session).not_to receive(:connect)
    expect(session).not_to receive(:close)
    result = collector.collect_session(session: session, target: target, platform: :h3c,
      dimensions: %i[access_points radios])
    expect(result).to be_complete
    expect(result.observation(:access_points).records).to be_empty
    expect(session).to have_received(:send_commands).with([ "display wlan ap all verbose" ]).once
  end

  it "collects shared AP and radio output once through the supplied connector" do
    expect(connector).to receive(:open).once.and_yield(session)
    result = collect(:access_points, :radios)

    expect(result).to be_complete
    expect(result.target.to_h).to eq(target.merge(platform: "h3c"))
    expect(result.observation(:access_points)).to be_complete
    expect(result.observation(:radios)).to be_complete
    expect(session).to have_received(:send_commands).with([ "display wlan ap all verbose" ]).once
    expect(result.observation(:clients).status).to eq(:not_requested)
  end

  it "retains the first inventory when the connector repeats the session callback" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-FIRST\nAP ID : 1\nState : Run\n"
    allow(connector).to receive(:open) do |&operation|
      operation.call(session)
      outputs["display wlan ap all verbose"] = "Total number of APs : 0\n"
      operation.call(session)
    end

    result = collect(:access_points)

    expect(result.records(:access_points)).to contain_exactly(include(name: "AP-FIRST"))
    expect(result.observation(:access_points)).to be_complete
    expect(result.issues).to eq([ { code: :session_reentered, stage: :close } ])
    expect(result).not_to be_complete
    expect(session).to have_received(:send_commands).with([ "screen-length disable" ]).once
    expect(session).to have_received(:send_commands).with([ "display wlan ap all verbose" ]).once
  end

  it "does not retry failed commands through a second supplied session" do
    second_session = double("Second CLI session", connected?: true)
    outputs["display wlan ap all verbose"] = IOError.new("private initial failure")
    allow(second_session).to receive(:send_commands) { |commands| session.send_commands(commands) }
    allow(connector).to receive(:open) do |&operation|
      operation.call(session)
      outputs["display wlan ap all verbose"] = "Total number of APs : 0\n"
      operation.call(second_session)
    end

    result = collect(:access_points)

    expect(result.observation(:access_points).status).to eq(:failed)
    expect(result.observation(:access_points).issues).to include(include(code: :command_execution_failed))
    expect(result.issues).to eq([ { code: :session_reentered, stage: :close } ])
    expect(second_session).not_to have_received(:send_commands)
  end

  it "continues independent client collection after the AP command fails" do
    outputs["display wlan ap all verbose"] = IOError.new("private transport detail")
    result = collect(:access_points, :clients)

    expect(result.observation(:access_points).status).to eq(:failed)
    expect(result.observation(:clients)).to be_complete
    expect(result.collection_status).to eq(:partial)
    expect(result.observation(:access_points).issues.inspect).not_to include("private transport detail")
  end

  it "keeps shared command failures and metadata separate from unrelated dimensions" do
    [ [ "\xff".b, :failed, :invalid_output ],
      [ "% Unrecognized command found at '^' position.\n", :unsupported, :unsupported_command ] ].each do |body, status, code|
      outputs["display wlan ap all verbose"] = body

      result = collect(:access_points, :radios, :clients)

      %i[access_points radios].each do |name|
        expect(result.observation(name).status).to eq(status)
        expect(result.observation(name).issues).to eq([ { code: code } ])
        expect(result.observation(name).evidence.map(&:to_h)).to contain_exactly(include(command: "display wlan ap all verbose"))
      end
      expect(result.observation(:access_points).started_at).to eq(result.observation(:radios).started_at)
      expect(result.observation(:access_points).evidence.map(&:to_h)).to eq(result.observation(:radios).evidence.map(&:to_h))
      expect(result.observation(:clients)).to be_complete
      expect(result.collection_status).to eq(:partial)
    end
  end

  it "keeps shared configuration projections partial without poisoning unrelated collection" do
    outputs["display current-configuration"] = "sysname WLC\nwlan service-template office\n ssid Office\n#\n--More--\nreturn\n"
    result = collect(:configuration, :ap_groups, :service_templates, :clients)

    %i[configuration ap_groups service_templates].each do |dimension|
      expect(result.observation(dimension)).to be_partial
    end
    expect(result.observation(:service_templates).records.first[:ssid]).to eq("Office")
    expect(result.observation(:clients)).to be_complete
    expect(result.collection_status).to eq(:partial)
    expect(session).to have_received(:send_commands).with([ "display current-configuration" ]).once
  end

  it "does not resolve nested AP credentials when LLDP was not requested" do
    credentials = double("Lazy AP credentials")
    expect(credentials).not_to receive(:call)

    expect(collect(:access_points, ap_credentials: credentials)).to be_complete
  end

  it "requires an explicit AP session factory while retaining the controller inventory" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    result = collect(:lldp)

    expect(result.observation(:access_points)).to be_complete
    expect(result.observation(:lldp).issues).to eq([ { code: :ap_session_required } ])
    expect(result.collection_status).to eq(:partial)
  end

  it "does not resolve AP credentials when no AP transport was injected" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    credentials = double("Lazy AP credentials")
    expect(credentials).not_to receive(:call)
    expect(collect(:lldp, ap_credentials: credentials).observation(:lldp).issues).to eq([ { code: :ap_session_required } ])
  end

  it "collects AP neighbors through a host-supplied reader without requiring a password" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    ap_reader = double("AP reader")
    now = Time.utc(2026, 10, 17)
    capture = CtxDriver::Capture.new(command: "display lldp neighbor-information verbose",
      body: "No LLDP neighbors\n", started_at: now, completed_at: now,
      evidence: [ { sha256: "a" * 64, bytes: 18 } ])
    expect(ap_reader).to receive(:read).with(access_point: include(name: "AP-LAB")).and_return(result: capture)
    factory = double("AP session factory")
    expect(factory).to receive(:call).with(controller: session).once.and_return(ap_reader)
    reader = described_class.new(ap_session_factory: factory)
    result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])
    expect(result.observation(:lldp)).to be_complete
    expect(result.observation(:lldp).evidence.first.to_h).to include(status: :complete, context: include(ap_name: "AP-LAB", attempted: true))
  end

  it "does not repeat AP enrichment when the connector yields again" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    ap_reader = double("AP reader", read: { error: :ap_not_online, skipped: true })
    factory = double("AP session factory", call: ap_reader)
    allow(connector).to receive(:open).and_yield(session).and_yield(session)

    result = described_class.new(ap_session_factory: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp ])

    expect(result.issues).to eq([ { code: :session_reentered, stage: :close } ])
    expect(result.observation(:lldp).evidence.map(&:to_h)).to contain_exactly(include(context: include(ap_name: "AP-LAB", attempted: false)))
    expect(factory).to have_received(:call).with(controller: session).once
    expect(ap_reader).to have_received(:read).with(access_point: include(name: "AP-LAB")).once
  end

  it "isolates an AP transport failure from controller observations and other APs" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 2\nAP name : AP-1\nAP ID : 1\nState : Run\nAP name : AP-2\nAP ID : 2\nState : Run\n"
    ap_reader = double("AP reader")
    expect(ap_reader).to receive(:read).with(access_point: include(name: "AP-1")).and_raise(IOError, "private endpoint")
    expect(ap_reader).to receive(:read).with(access_point: include(name: "AP-2")).and_return(error: :ap_not_online, skipped: true)
    reader = described_class.new(ap_session_factory: ->(controller:) { ap_reader })
    result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp, :clients ])
    expect(result.observation(:clients)).to be_complete
    expect(result.observation(:access_points)).to be_complete
    expect(result.observation(:lldp).status).to eq(:failed)
    expect(result.observation(:lldp).issues).to include(include(ap_name: "AP-1"), include(code: :ap_not_online, ap_name: "AP-2"))
    expect(result.observation(:lldp).issues.inspect).not_to include("private endpoint")
  end

  it "binds AP evidence to the selected AP and LLDP command while retaining capture metadata" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    now = Time.utc(2026, 10, 17)
    command = Wireless::H3c::Profile::DECLARATIONS.by_dimension.fetch(:lldp)
    capture = CtxDriver::Capture.new(command: command, body: "No LLDP neighbors\n", started_at: now, completed_at: now,
      evidence: [ { sha256: "a" * 64, bytes: 18, observed_at: now.iso8601,
        command: "unrelated-command", status: :failed, context: { kind: :other, ap_name: "OTHER-AP", attempted: false, neighbor_count: 99 } } ])
    ap_reader = double("AP reader", read: { result: capture })
    reader = described_class.new(ap_session_factory: ->(controller:) { ap_reader })

    result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])

    expect(result.observation(:lldp)).to be_complete
    expect(result.observation(:lldp).evidence.map(&:to_h)).to eq([ { sha256: "a" * 64, bytes: 18, observed_at: now.iso8601(6),
      command: command, status: :complete, context: { kind: :ap_lldp_result, ap_name: "AP-LAB", attempted: true, neighbor_count: 0 } } ])
  end

  it "rejects wrong-command and skipped successful AP captures without losing controller facts" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    now = Time.utc(2026, 10, 17)
    [ { command: "display unrelated", skipped: false },
      { command: Wireless::H3c::Profile::DECLARATIONS.by_dimension.fetch(:lldp), skipped: true } ].each do |attributes|
      capture = CtxDriver::Capture.new(command: attributes[:command], body: "No LLDP neighbors\n",
        started_at: now, completed_at: now)
      ap_reader = double("AP reader", read: { result: capture, skipped: attributes[:skipped] })
      reader = described_class.new(ap_session_factory: ->(controller:) { ap_reader })

      result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])

      expect(result.observation(:access_points)).to be_complete
      expect(result.observation(:lldp).status).to eq(:failed)
      expect(result.observation(:lldp).issues).to include(include(code: :invalid_command_result, stage: :response, ap_name: "AP-LAB"))
      expect(result.observation(:lldp).evidence.first.to_h).to include(status: :failed, context: include(ap_name: "AP-LAB", neighbor_count: 0))
    end
  end

  it "rejects malformed AP outcomes at the response boundary without losing controller facts" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    [ nil, [], { result: false }, { skipped: "false" }, { skipped: nil } ].each do |outcome|
      ap_reader = double("AP reader", read: outcome)
      reader = described_class.new(ap_session_factory: ->(controller:) { ap_reader })

      result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp, :clients ])

      expect(result.observation(:access_points)).to be_complete
      expect(result.observation(:clients)).to be_complete
      expect(result.observation(:lldp).issues).to include(include(code: :invalid_command_result, stage: :response))
      expect(result.observation(:lldp).evidence.first.to_h).to include(status: :failed, context: include(ap_name: "AP-LAB", attempted: true))
    end
  end

  it "normalizes non-symbol AP failure codes while retaining captured neighbor facts" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    now = Time.utc(2026, 10, 17)
    capture = CtxDriver::Capture.new(command: Wireless::H3c::Profile::DECLARATIONS.by_dimension.fetch(:lldp),
      body: "LLDP neighbor-information of port 1[GE1]:\nLLDP neighbor index: 1\nChassis ID: switch\nPort ID: GE2\n",
      started_at: now, completed_at: now)
    %i[error cleanup_error close_error].each do |key|
      ap_reader = double("AP reader", read: { result: capture, key => "private adapter detail" })
      reader = described_class.new(ap_session_factory: ->(controller:) { ap_reader })

      result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])

      expect(result.observation(:access_points)).to be_complete
      expect(result.observation(:lldp)).to be_partial
      expect(result.records(:lldp)).to contain_exactly(include(local_interface: "GE1", remote_interface: "GE2", ap_name: "AP-LAB"))
      expect(result.observation(:lldp).issues).to eq([ { code: :invalid_command_result, ap_name: "AP-LAB" } ])
      expect(result.observation(:lldp).evidence.first.to_h).to include(status: :failed, context: include(neighbor_count: 1))
    end
  end

  it "retains safe failed AP capture diagnostics and skipped execution without duplicate outcome fields" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    now = Time.utc(2026, 10, 17)
    capture = CtxDriver::Capture.new(command: Wireless::H3c::Profile::DECLARATIONS.by_dimension.fetch(:lldp),
      started_at: now, completed_at: now, skipped: true,
      failure: { code: :session_closed, stage: :session, error_type: "IOError", message: "private device text" })
    ap_reader = double("AP reader", read: { result: capture })
    reader = described_class.new(ap_session_factory: ->(controller:) { ap_reader })

    result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])

    expect(result.observation(:access_points)).to be_complete
    expect(result.observation(:lldp).issues).to eq([ { code: :session_closed, stage: :session, error_type: "IOError", ap_name: "AP-LAB" } ])
    expect(result.observation(:lldp).evidence.first.to_h).to include(status: :failed, context: include(attempted: false))
  end

  it "combines AP skipped flags and does not repeat the capture failure as an outcome error" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    now = Time.utc(2026, 10, 17)
    capture = CtxDriver::Capture.new(command: Wireless::H3c::Profile::DECLARATIONS.by_dimension.fetch(:lldp),
      started_at: now, completed_at: now, failure: { code: :session_closed, stage: :session })
    ap_reader = double("AP reader", read: { result: capture, error: :session_closed, skipped: true })
    reader = described_class.new(ap_session_factory: ->(controller:) { ap_reader })

    result = reader.collect(connector: connector, target: target, platform: :h3c, dimensions: [ :lldp ])

    expect(result.observation(:lldp).issues).to eq([ { code: :session_closed, stage: :session, ap_name: "AP-LAB" } ])
    expect(result.observation(:lldp).evidence.first.to_h).to include(status: :failed, context: include(attempted: false))
  end

  it "does not construct an AP reader or resolve credentials for an empty complete inventory" do
    factory, credentials = double("AP factory"), double("AP credentials")
    expect(factory).not_to receive(:call)
    expect(credentials).not_to receive(:call)
    result = described_class.new(ap_session_factory: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp ], ap_credentials: credentials)
    expect(result.observation(:lldp)).to be_complete
    expect(result.observation(:lldp).records).to be_empty
  end

  it "does not require an AP transport when the controller reports no APs" do
    result = collect(:lldp)
    expect(result).to be_complete
    expect(result.observation(:lldp)).to be_complete
  end

  it "keeps AP setup failures separate from controller connection failures" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    factory = ->(controller:) { raise IOError, "private adapter details" }
    result = described_class.new(ap_session_factory: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp, :clients ])
    expect(result.observation(:clients)).to be_complete
    expect(result.observation(:access_points)).to be_complete
    expect(result.observation(:lldp).issues).to include(include(code: :ap_session_setup_failed, stage: :ap_setup))
    expect(result.collection_status).to eq(:partial)
    expect(result.observation(:lldp).issues.inspect).not_to include("private adapter details")
  end

  it "snapshots target identity before opening an external session" do
    allow(connector).to receive(:open) do |&operation|
      target[:host].replace("192.0.2.99")
      operation.call(session)
    end
    result = collect(:access_points)
    expect(result.target.host).to eq("192.0.2.10")
    expect(target[:host]).to eq("192.0.2.99")
  end

  it "keeps platform and model selection stable across connector callbacks" do
    platform, model = +"h3c", +"WX-LAB"
    allow(connector).to receive(:open) do |&operation|
      platform.replace("huawei")
      model.replace("changed-model")
      operation.call(session)
    end
    result = collector.collect(connector: connector, target: target, platform: platform,
      model: model, dimensions: [ :access_points ])

    expect(result.observation(:access_points)).to be_complete
    expect(session).to have_received(:send_commands).with([ "screen-length disable" ])
    expect(platform).to eq("huawei")
    expect(model).to eq("changed-model")
  end

  it "uses the model parser selected before opening the connector" do
    selected_parser = Class.new(CtxParser::Parser) do
      private

      # 使用独立字面量区分请求前已选策略与回调后的声明。
      def parse_output(text, complete:)
        CtxParser::Result.new(status: :complete, records: [ { name: "AP-SELECTED" } ])
      end
    end
    command = "display wlan ap all verbose"
    overrides = { command => selected_parser }
    profile = Class.new(Wireless::H3c::Profile)
    profile.const_set(:MODEL_PARSERS, { "wx-lab" => overrides })
    registry = CtxParser::Registry.new(profiles: { h3c: profile }, aliases: { h3c_wireless: :h3c })
    stub_const("Wireless::ParserRegistry", registry)
    allow(connector).to receive(:open) do |&operation|
      overrides.clear
      operation.call(session)
    end

    result = collect(:access_points, model: "WX-LAB")

    expect(result.observation(:access_points)).to be_complete
    expect(result.records(:access_points)).to eq([ { name: "AP-SELECTED" } ])
    expect(result.observation(:access_points).evidence.map(&:to_h)).to contain_exactly(include(command: command))
    expect(result.observation(:access_points).started_at).to be_a(Time)
    expect(result.observation(:access_points).completed_at).to be_a(Time)
  end

  it "keeps the borrowed controller authoritative over AP credential options" do
    outputs["display wlan ap all verbose"] = "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n"
    ap_reader = double("AP reader", read: { error: :ap_not_online, skipped: true })
    factory = double("AP factory")
    expect(factory).to receive(:call).with(controller: session, password: "example").and_return(ap_reader)

    result = described_class.new(ap_session_factory: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp ], ap_credentials: { controller: Object.new, password: "example" })

    expect(result.observation(:access_points)).to be_complete
    expect(result.observation(:lldp).issues).to include(code: :ap_not_online, ap_name: "AP-LAB")
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
    result = described_class.new(ap_session_factory: factory).collect(connector: connector, target: target,
      platform: :h3c, dimensions: [ :lldp ], ap_names: selected)
    expect(result.observation(:lldp).evidence.map { |entry| entry.context[:ap_name] }).to eq([ "AP-1" ])
  end

  it "retains acquired facts when closing the injected session fails" do
    allow(connector).to receive(:open) do |&operation|
      operation.call(session)
      raise IOError, "private close diagnostic"
    end
    result = collect(:access_points)

    expect(result.observation(:access_points)).to be_complete
    expect(result.issues).to eq([ { code: :session_close_failed, stage: :close, error_type: "IOError" } ])
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
