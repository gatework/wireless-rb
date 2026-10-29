# frozen_string_literal: true

require_relative "spec_helper"
require "wireless/ap_session"

RSpec.describe Wireless::ApSession do
  let(:controller) { double("Controller session") }
  let(:ap) { { name: "AP-LAB", management_ip: "192.0.2.7", operational_status: "Run" } }
  let(:reader) { described_class.new(controller: controller, password: "test-ap-password") }
  let(:commands) { [] }

  before do
    @prompt, @connected = "<WLC>", true
    allow(controller).to receive(:current_prompt) { @prompt }
    allow(controller).to receive(:connected?) { @connected }
    allow(controller).to receive(:close) { @connected = false }
    allow(controller).to receive(:with_operation).with(:wireless_ap_lldp).and_yield
    allow(controller).to receive(:execute_operation) do |script, **options|
      expect(options).to eq(name: :wireless_ap_lldp, privilege: false)
      command = only_record(script.to_a)
      expect(command).to have_attributes(sensitive?: true, output_sensitive?: true)
      commands << command.text
      @prompt = command.text == "quit" ? "<WLC>" : "<AP-LAB>"
      receipt(command, "", @prompt)
    end
    allow(controller).to receive(:send_commands) do |texts|
      commands << only_record(texts)
      query_receipt(Net::Connector::Command.new(only_record(texts)), "No LLDP neighbors\n", @prompt)
    end
  end

  # 借用会话返回 Driver 协议；原生交互仍使用连接器回执。
  def query_receipt(command, body, prompt)
    Struct.new(:output, :steps, :body) do
      def success? = true
      def value! = body
    end.new("#{command.text}\r\n#{body}#{prompt}", [ { command: command.text } ], body)
  end

  def receipt(command, body, prompt, error: nil)
    Net::Connector::Result.new(steps: [ Net::Connector::Command::Result.new(command: command,
      output: "#{command.text}\r\n#{body}#{prompt}", prompt: prompt, duration: 0.1) ], config: body, error: error)
  end

  # 真实连接器处理提示符、交互和租约；只有底层字节收发使用合成传输。
  def controller_with_events(events, writes)
    closed = true
    transport = double("Byte transport", protocol: :fake)
    allow(transport).to receive(:log_output=)
    allow(transport).to receive(:closed?) { closed }
    allow(transport).to receive(:open) { closed = false }
    allow(transport).to receive(:close) { closed = true }
    allow(transport).to receive(:write) { |bytes, **| writes << bytes; bytes.bytesize }
    allow(transport).to receive(:read) do |patterns, **|
      body = events.shift
      raise "Unexpected transport read" unless body
      body = body.b
      index = patterns.index { |pattern| pattern.match?(body) }
      raise "Missing expected prompt or interaction" unless index
      match = patterns[index].match(body)
      Net::Connector::Event.new(index: index, before: body.byteslice(0, match.begin(0)), match: match[0])
    end
    Net::Connector.build(:h3c_wireless, host: "192.0.2.1", username: "test-user",
      password: "controller-password", transport: transport)
  end

  it "rejects a missing controller protocol and blank optional usernames before login" do
    expect { described_class.new(controller: Object.new, password: "test") }.to raise_error(ArgumentError)
    expect { described_class.new(controller: controller, password: "test", username: "  ") }.to raise_error(ArgumentError)
    expect(controller).not_to have_received(:execute_operation)
  end

  it "confirms AP entry, executes readonly queries, then confirms return to the exact controller prompt" do
    outcome = reader.read(access_point: ap)
    expect(outcome.keys).to eq([ :result ])
    expect(outcome[:result].body).to eq("No LLDP neighbors\n")
    expect(commands).to eq([ "telnet 192.0.2.7", "screen-length disable", "display lldp neighbor-information verbose", "quit" ])
    expect(@prompt).to eq("<WLC>")
    expect(controller).not_to have_received(:close)
    expect(reader.inspect).not_to include("test-ap-password")
  end

  it "sends the password as a bounded hidden interaction" do
    expect(controller).to receive(:execute_operation) do |script, **|
      command = only_record(script.to_a)
      expect(command.text).to eq("telnet 192.0.2.7")
      interaction = only_record(command.interactions)
      expect(interaction.inspect).not_to include("test-ap-password")
      expect(interaction).to have_attributes(sensitive?: true, limit: 1, capture?: false)
      receipt(command, "", "<WLC>")
    end
    expect(reader.read(access_point: ap)[:error]).to eq(:ap_login_not_confirmed)
    expect(controller).not_to have_received(:send_commands)
  end

  it "owns validated credential copies without freezing or retaining caller strings" do
    password, username = +"original-password", +"original-user"
    session = described_class.new(controller: controller, password: password, username: username)
    password.replace("changed\ncommand")
    username.replace("changed\ncommand")
    expect(controller).to receive(:execute_operation) do |script, **|
      command = only_record(script.to_a)
      expect(command.interactions.map(&:static_response)).to eq([ "original-user\n", "original-password\n" ])
      receipt(command, "", "<WLC>")
    end
    expect(session.read(access_point: ap)[:error]).to eq(:ap_login_not_confirmed)
    expect(password).not_to be_frozen
    expect(username).not_to be_frozen
  end

  it "never queries the controller when AP login returns the original prompt" do
    allow(controller).to receive(:execute_operation) { |script, **| receipt(only_record(script.to_a), "", "<WLC>") }
    outcome = reader.read(access_point: ap)
    expect(outcome[:error]).to eq(:ap_login_not_confirmed)
    expect(controller).not_to have_received(:send_commands)
  end

  it "distinguishes a closed Telnet connection from a rejected password and never submits AP queries" do
    [ [ "The connection was closed by the remote host!", :ap_connection_failed ],
      [ "Authentication failed\nConnection closed", :ap_authentication_failed ] ].each do |message, code|
      allow(controller).to receive(:execute_operation) do |script, **|
        @prompt = "<WLC>"
        receipt(only_record(script.to_a), "#{message}\n", @prompt)
      end
      expect(reader.read(access_point: ap)).to eq(error: code)
    end
    expect(controller).not_to have_received(:send_commands)
    expect(controller).not_to have_received(:close)
  end

  it "closes an unconfirmed login even if the last cached prompt was still the controller" do
    allow(controller).to receive(:execute_operation).and_return(Net::Connector::Result.new(error: Net::Connector::CommandTimeout.new("private login", code: :command_timeout)))
    outcome = reader.read(access_point: ap)
    expect(outcome[:error]).to eq(:command_timeout)
    expect(controller).to have_received(:close).once
    expect(reader.read(access_point: ap)).to eq(error: :controller_session_lost, skipped: true)
    expect(controller).not_to have_received(:send_commands)
  end

  it "stops after an unconfirmed return instead of issuing a second Telnet from inside the AP" do
    allow(controller).to receive(:execute_operation) do |script, **|
      command = only_record(script.to_a)
      @prompt = "<AP-LAB>"
      receipt(command, "", @prompt)
    end
    outcome = reader.read(access_point: ap)
    expect(outcome[:cleanup_error]).to eq(:ap_exit_failed)
    expect(outcome[:result]).to be_success
    expect(controller).to have_received(:close).once
    expect(reader.read(access_point: ap)).to eq(error: :controller_session_lost, skipped: true)
  end

  it "skips offline and invalid AP endpoints without any transport operation" do
    expect(reader.read(access_point: ap.merge(operational_status: "Idle"))).to eq(error: :ap_not_online, skipped: true)
    expect(reader.read(access_point: ap.merge(management_ip: "192.0.2.7;shutdown"))).to eq(error: :ap_address_unavailable, skipped: true)
    expect(controller).not_to have_received(:execute_operation)
    expect(controller).not_to have_received(:send_commands)
    expect { described_class.new(controller: controller, password: "bad\npassword") }.to raise_error(ArgumentError)
  end

  it "closes a damaged nested session before releasing the controller operation" do
    owned = false
    allow(controller).to receive(:with_operation) do |_, &operation|
      owned = true
      begin
        operation.call
      ensure
        owned = false
      end
    end
    allow(controller).to receive(:execute_operation) do |script, **|
      @prompt = "<AP-LAB>"
      receipt(only_record(script.to_a), "", @prompt)
    end
    expect(controller).to receive(:close) do
      expect(owned).to be(true)
      @connected = false
    end
    expect(reader.read(access_point: ap)[:cleanup_error]).to eq(:ap_exit_failed)
  end

  it "does not close or poison a controller owned by another operation" do
    allow(controller).to receive(:with_operation).and_raise(Net::Connector::SessionBusy.new("private owner", code: :session_busy))
    expect(controller).not_to receive(:close)
    expect(reader.read(access_point: ap)).to eq(error: :session_busy, skipped: true)
    allow(controller).to receive(:with_operation).and_yield
    expect(reader.read(access_point: ap)[:result]).to be_success
  end

  it "propagates login cancellation after closing the uncertain controller inside its operation" do
    allow(controller).to receive(:execute_operation).and_raise(Interrupt, "cancelled")
    expect { reader.read(access_point: ap) }.to raise_error(Interrupt)
    expect(controller).to have_received(:close).once
    expect(reader.read(access_point: ap)).to eq(error: :controller_session_lost, skipped: true)
  end

  it "does not classify an exception after login began as a skipped address validation failure" do
    allow(controller).to receive(:execute_operation).and_raise(ArgumentError, "private adapter failure")
    outcome = reader.read(access_point: ap)
    expect(outcome).to include(error: :collection_failed, cleanup_error: :ap_exit_failed)
    expect(outcome).not_to have_key(:skipped)
    expect(outcome.inspect).not_to include("private adapter failure")
    expect(controller).to have_received(:close).once
  end

  it "preserves exit and close failures as independent diagnostics" do
    allow(controller).to receive(:execute_operation) do |script, **|
      @prompt = "<AP-LAB>"
      receipt(only_record(script.to_a), "", @prompt)
    end
    allow(controller).to receive(:close).and_raise(IOError, "private close")
    outcome = reader.read(access_point: ap)
    expect(outcome).to include(cleanup_error: :ap_exit_failed, close_error: :session_close_failed)
    expect(outcome[:result]).to be_success
    expect(reader.read(access_point: ap)).to eq(error: :controller_session_lost, skipped: true)
  end

  it "does not send quit to the controller after the AP transport has already returned" do
    allow(controller).to receive(:send_commands) do |texts|
      command = only_record(texts)
      @prompt = "<WLC>"
      query_receipt(Net::Connector::Command.new(command), "", @prompt)
    end
    outcome = reader.read(access_point: ap)
    expect(outcome[:error]).to eq(:ap_session_lost)
    expect(outcome).not_to have_key(:result)
    expect(commands).to eq([ "telnet 192.0.2.7" ])
    expect(controller).not_to have_received(:close)
  end

  it "does not send quit from an unexpected nested prompt" do
    allow(controller).to receive(:send_commands) do |texts|
      @prompt = "<UNEXPECTED>"
      query_receipt(Net::Connector::Command.new(only_record(texts)), "", @prompt)
    end
    outcome = reader.read(access_point: ap)
    expect(outcome).to include(error: :ap_session_lost, cleanup_error: :ap_exit_failed)
    expect(commands).to eq([ "telnet 192.0.2.7" ])
    expect(controller).to have_received(:close).once
  end

  it "retires an uncertain real controller before releasing its operation lease" do
    events = [ "<WLC>", "telnet 192.0.2.7\r\nPassword:", "\r\n<AP-LAB>",
      "screen-length disable\r\n<AP-LAB>", "display lldp neighbor-information verbose\r\nNo LLDP neighbors\r\n<AP-LAB>",
      "quit\r\n<UNEXPECTED>" ]
    actual = controller_with_events(events, [])
    actual.connect
    allow(actual).to receive(:close).and_wrap_original do |close|
      lock = actual.instance_variable_get(:@session).instance_variable_get(:@lock)
      expect(lock.owned?).to be(true)
      close.call
    end
    result = described_class.new(controller: actual, password: "test-ap-password").read(access_point: ap)
    expect(result[:result]).to be_success
    expect(result[:cleanup_error]).to eq(:ap_exit_failed)
    expect(result).not_to have_key(:close_error)
    expect(actual).not_to be_connected
    expect(events).to be_empty
  ensure
    allow(actual).to receive(:close).and_call_original if actual
    actual&.close
  end

  it "retires a cancelled login before releasing the borrowed operation" do
    entered, blocked = Queue.new, Queue.new
    owned = false
    allow(controller).to receive(:with_operation) do |_, &operation|
      owned = true
      begin
        operation.call
      ensure
        owned = false
      end
    end
    allow(controller).to receive(:execute_operation) { entered << true; blocked.pop }
    expect(controller).to receive(:close) { expect(owned).to be(true); @connected = false }
    ap_session = reader
    worker = Thread.new { ap_session.read(access_point: ap) }
    entered.pop
    worker.kill
    expect(worker.join(2)).to equal(worker)
    expect(ap_session.read(access_point: ap)).to eq(error: :controller_session_lost, skipped: true)
  ensure
    worker&.kill&.join
  end

  it "preserves the first cancellation if cleanup is also interrupted" do
    first = Interrupt.new("first cancellation")
    second = Interrupt.new("cleanup cancellation")
    cause = RuntimeError.new("original cause")
    ap_session = reader
    allow(controller).to receive(:send_commands) { raise first, cause: cause }
    allow(controller).to receive(:execute_operation) do |script, **|
      command = only_record(script.to_a)
      raise second if command.text == "quit"
      @prompt = "<AP-LAB>"
      receipt(command, "", @prompt)
    end
    expect { ap_session.read(access_point: ap) }.to raise_error { |error| expect(error).to equal(first); expect(error.cause).to equal(cause) }
    expect(controller).to have_received(:close).once
  end

  it "runs the nested operation through the actual local net-connector using a scripted byte transport" do
    events = [ "<WLC>", "telnet 192.0.2.7\r\nPassword:", "\r\n<AP-LAB>",
      "screen-length disable\r\n<AP-LAB>", "display lldp neighbor-information verbose\r\nNo LLDP neighbors\r\n<AP-LAB>",
      "quit\r\n<WLC>" ]
    writes = []
    actual = controller_with_events(events, writes)
    actual.connect
    password = +"test-ap-password"
    session = described_class.new(controller: actual, password: password)
    password.replace("changed\ncommand")
    result = session.read(access_point: ap)
    expect(result.keys).to eq([ :result ])
    expect(result[:result].body).to eq("No LLDP neighbors\n")
    expect(actual.current_prompt).to eq("<WLC>")
    expect(writes).to eq([ "telnet 192.0.2.7\n", "test-ap-password\n", "screen-length disable\n",
      "display lldp neighbor-information verbose\n", "quit\n" ])
    expect(actual).not_to be_privileged
    expect(events).to be_empty
  ensure
    actual&.close
  end
end
