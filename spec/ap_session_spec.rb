# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"

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
      receipt(Net::Connector::Command.new(only_record(texts)), "No LLDP neighbors\n", @prompt)
    end
  end

  def receipt(command, body, prompt, error: nil)
    Net::Connector::Result.new(steps: [ Net::Connector::CommandResult.new(command: command,
      output: "#{command.text}\r\n#{body}#{prompt}", prompt: prompt, duration: 0.1) ], config: body, error: error)
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
    allow(controller).to receive(:execute_operation).and_return(Net::Connector::Result.new(error: Net::Connector::CommandTimeout.new("private login")))
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

  it "runs the nested operation through the actual local net-connector using a scripted byte transport" do
    events = [ "<WLC>", "telnet 192.0.2.7\r\nPassword:", "\r\n<AP-LAB>",
      "screen-length disable\r\n<AP-LAB>", "display lldp neighbor-information verbose\r\nNo LLDP neighbors\r\n<AP-LAB>",
      "quit\r\n<WLC>" ]
    writes = []
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
    actual = Net::Connector.build(:h3c_wireless, host: "192.0.2.1", username: "test-user",
      password: "controller-password", transport: transport)
    actual.connect
    result = described_class.new(controller: actual, password: "test-ap-password").read(access_point: ap)
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
