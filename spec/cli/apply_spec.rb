# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli"
require "wireless/cli/report"
require "wireless/change_plan"
require "tmpdir"
require "stringio"
require "digest"
require "json"

RSpec.describe "Wireless interactive apply" do
  let(:config) { { "service_templates" => [ { "name" => "lab", "enabled" => true, "configuration" => { "cipher_suites" => %w[ccmp tkip], "security_ies" => %w[rsn wpa] } } ] } }
  let(:change) { { "kind" => "wireless_security", "name" => "lab", "enabled" => true, "cipher_suites" => %w[ccmp tkip], "security_ies" => %w[rsn wpa] } }
  let(:after_config) do
    updated = Marshal.load(Marshal.dump(config))
    updated["service_templates"][0]["configuration"] = { "cipher_suites" => [ "ccmp" ], "security_ies" => [ "rsn" ] }
    updated
  end

  # 模拟真实终端及设备边界，避免单元测试接触网络。
  def terminal(text = "")
    stream = StringIO.new(text.dup)
    stream.define_singleton_method(:tty?) { true }
    stream
  end

  def exercise(confirmation: true, tty: true, drift: false, fail_write: false, altered: false, persistence_failure: false, failed_readback: false, checkpoint_failure: false, file_credentials: false, callback_count: 1)
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".env"), "NC_DEVICE_USERNAME=file-user\nNC_DEVICE_PASSWORD=private-file-secret\n") if file_credentials
      process_environment = file_credentials ? { "NC_DEVICE_USERNAME" => "process-user" } : { "NC_DEVICE_USERNAME" => "test" }
      credentials = []
      commands, rollback = Wireless::ChangePlan.render(change)
      plan = { schema_version: 1, platform: "h3c_wireless", device: { "host" => "192.0.2.1", "name" => "test" }, expected_config_sha256: Wireless::ChangePlan.fingerprint(config), change: change, commands: commands, rollback: rollback, prerequisites: [], impact: "test" }
      plan[:commands] = [ "reboot" ] if altered
      path = File.join(root, "plan.json")
      File.write(path, JSON.generate(plan))
      token = "APPLY 192.0.2.1 #{Digest::SHA256.file(path).hexdigest[0, 12]}"
      input = tty ? terminal(confirmation ? "#{token}\n" : "no\n") : StringIO.new("#{token}\n")
      out, error = terminal, terminal
      writes, connections, reads = [], [], []
      before, after = config, failed_readback ? config : after_config
      session = Object.new
      session.define_singleton_method(:read_configuration) do
        reads << true
        writes.empty? ? (drift ? before.merge("drift" => true) : before) : after
      end
      session.define_singleton_method(:write) do |command|
        writes << command
        raise IOError, "private-error-detail" if fail_write
        true
      end
      factory = lambda do |device, settings, &block|
        connections << device
        credentials << settings
        callback_count.times { block.call(session) }
      end
      if persistence_failure
        allow_any_instance_of(Wireless::CLI::Report).to receive(:write_execution).and_raise(Errno::ENOSPC)
      end
      if checkpoint_failure
        count = 0
        allow_any_instance_of(Wireless::CLI::Report).to receive(:write_execution).and_wrap_original do |original, state|
          count += 1
          raise Errno::ENOSPC if count == 3
          original.call(state)
        end
      end
      status = Wireless::CLI.run([ "apply", "--plan", path, "--directory", File.join(root, "execution") ], env: process_environment, out: out, error: error, input: input, connector_factory: factory, discovery: { directories: [ root ], home: root, cwd: root })
      journals = Dir[File.join(root, "execution", "*", "execution.json")].map { |file| JSON.parse(File.read(file)) }
      { status: status, reads: reads, writes: writes, connections: connections, journals: journals, error: error.string, credentials: credentials, environment: process_environment }
    end
  end

  it "loads automatic credentials without polluting the input environment" do
    result = exercise(file_credentials: true)
    expect(result).to include(status: 0, environment: { "NC_DEVICE_USERNAME" => "process-user" })
    expect(result[:credentials]).to all(include(username: "process-user", password: "private-file-secret"))
    expect(result[:journals].to_s + result[:error]).not_to include("private-file-secret")
  end

  it "requires an exact interactive confirmation and never connects on cancellation" do
    result = exercise(confirmation: false)
    expect(result).to include(status: 1, connections: [], writes: [])
  end

  it "rejects piped confirmations before connecting" do
    expect(exercise(tty: false)).to include(status: 2, connections: [], writes: [])
  end

  it "rejects drift after reading but before any configuration command" do
    expect(exercise(drift: true)).to include(status: 2, writes: [])
  end

  it "does not execute arbitrary edited commands from a plan" do
    expect(exercise(altered: true)).to include(status: 2, connections: [], writes: [])
  end

  it "writes no commands when durable intent cannot be saved" do
    expect(exercise(persistence_failure: true)).to include(status: 2, writes: [])
  end

  it "stops on the first uncertain command without retry or rollback" do
    result = exercise(fail_write: true)
    expect(result[:status]).to eq(2)
    expect(result[:writes].size).to eq(1)
    expect(result[:journals].last).to include("status" => "uncertain")
    expect(result[:error]).not_to include("private-error-detail")
  end

  it "does not claim success when the readback still has the original configuration" do
    result = exercise(failed_readback: true)
    expect(result[:status]).to eq(2)
    expect(result[:journals].last).to include("status" => "uncertain")
  end

  it "stops after the first command if its acknowledgement cannot be persisted" do
    result = exercise(checkpoint_failure: true)
    expect(result[:status]).to eq(2)
    expect(result[:writes].size).to eq(1)
    expect(result[:journals].last).to include("status" => "uncertain")
  end

  it "rejects a connector that never opens a session" do
    result = exercise(callback_count: 0)
    expect(result).to include(status: 2, writes: [], reads: [])
    expect(result[:journals].last).to include("status" => "failed")
  end

  it "rejects repeated session callbacks before repeating device reads or writes" do
    result = exercise(callback_count: 2)
    expect(result[:status]).to eq(2)
    expect(result[:reads].size).to eq(2)
    expect(result[:writes]).to eq(Wireless::ChangePlan.render(change).first)
    expect(result[:journals].last).to include("status" => "uncertain")
  end

  it "confirms completion only after a configuration readback" do
    result = exercise
    expect(result[:status]).to eq(0), result[:error]
    expect(result[:journals].last).to include("status" => "configuration_verified")
    expect(result[:writes].last).to eq("return")
  end
end
