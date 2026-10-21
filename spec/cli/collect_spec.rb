# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli/collect"
require "tmpdir"
require "stringio"
require "timeout"

RSpec.describe Wireless::CLI::Collect do
  # 合成设备回执只替代传输；解析、调度和报告使用真实实现。
  class WirelessFixtureSession
    attr_reader :commands

    def initialize(platform, ap_body: "Total number of APs : 0\n")
      @platform, @ap_body, @commands = platform, ap_body, []
    end

    def connected? = true

    def send_commands(commands)
      @commands.concat(commands)
      command = commands.fetch(0)
      body = case command
      when "screen-length disable", "screen-length 0 temporary" then ""
      when "display wlan ap all verbose" then @ap_body
      when "display station all" then "STA MAC AP ID Ap name Rf/WLAN\nTotal: 0\n"
      when "display ap all" then "ID MAC Name Group IP Type State STA Uptime\nTotal: 0\n"
      when "display current-configuration" then "sysname WLC\nreturn\n"
      else raise "Unexpected query"
      end
      Struct.new(:output, :steps, :body) do
        def success? = true
        def value! = body
      end.new("#{command}\n#{body}<WLC>", [ Object.new ], body)
    end
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory, @out, @error = directory, StringIO.new, StringIO.new
      @env = { "NC_DEVICE_USERNAME" => "fixture-user" }
      @config = File.join(directory, "wireless.yml")
      File.write(File.join(directory, "fixture.env"), "")
      example.run
    end
  end

  it "shares address, name, vendor and model selection without opening sessions" do
    config(devices: [ { "host" => "192.0.2.10", "name" => "EDGE", "model" => "S6800" },
      { "host" => "192.0.2.11", "name" => "EDGE-spare", "model" => "S6800" } ])
    args = [ "--plan", "--json", "--hosts", "192.0.2.1-20", "--name", "edge", "--exclude-name", "spare",
      "--vendor", "h3c", "--model", "s68*", "--model-match", "glob" ]
    expect(run_cli(*args)).to eq(0)
    expect(JSON.parse(@out.string).map { |row| row.fetch("host") }).to eq([ "192.0.2.10" ])
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end

  def config(**overrides)
    File.write(@config, YAML.dump({ "directory" => File.join(@directory, "reports"), "dimensions" => [ "access_points" ],
      "devices" => [ { "host" => "192.0.2.10", "name" => "WLC", "platform" => "h3c" } ] }.merge(overrides.transform_keys(&:to_s))))
  end

  def run_cli(*args, factory: nil, executor: nil, **options)
    described_class.new(env: @env, out: @out, error: @error, input: StringIO.new, discovery: { directories: [ @directory ], home: @directory, cwd: @directory },
      connector_factory: factory, executor: executor, **options).run([ "--config", @config, "--env-file", File.join(@directory, "fixture.env"), *args ])
  end

  def factory_for(sessions, failed: [])
    lambda do |device, _credentials|
      connector = double("connector", platform: device.fetch("platform"))
      if failed.include?(device.fetch("host"))
        allow(connector).to receive(:open).and_raise(IOError, "private diagnostic")
      else
        allow(connector).to receive(:open).and_yield(sessions.fetch(device.fetch("host")))
      end
      connector
    end
  end

  it "rejects insufficient device resources before connecting or creating a report" do
    config
    allow(Process).to receive(:getrlimit).with(:NOFILE).and_return([ 140, 140 ])
    factory = ->(*) { raise "connection must not start" }
    expect(run_cli(factory: factory)).to eq(2)
    expect(@error.string).to include("文件描述符额度不足", "未连接设备")
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end

  it "reserves resources for selected devices rather than the configured maximum" do
    config(parallel: 50)
    allow(Process).to receive(:getrlimit).with(:NOFILE).and_return([ 150, 150 ])
    factory = factory_for({ "192.0.2.10" => WirelessFixtureSession.new(:h3c) })
    expect(run_cli("--json", factory: factory)).to eq(0)
    expect(JSON.parse(@out.string)).to include("completed" => 1)
  end

  it "closes concurrent sessions before publishing an interrupted batch" do
    config(parallel: 2, devices: [
      { "host" => "192.0.2.10", "name" => "WLC-1", "platform" => "h3c" },
      { "host" => "192.0.2.11", "name" => "WLC-2", "platform" => "h3c" }
    ])
    started, blocked, closed = Queue.new, Queue.new, Queue.new
    factory = lambda do |device, _settings|
      connector = double("connector", platform: :h3c)
      allow(connector).to receive(:open) do
        begin
          if device.fetch("host").end_with?("10")
            started.pop
            raise Interrupt
          end
          started << true
          blocked.pop
        ensure
          closed << Thread.current
        end
      end
      connector
    end
    status = Timeout.timeout(2) { run_cli("--quiet", "--json", factory: factory) }
    expect(status).to eq(130)
    expect(closed.size).to eq(2)
    expect(2.times.map { closed.pop }).to all(satisfy { |worker| !worker.alive? })
    expect(JSON.parse(@out.string)).to include("status" => "interrupted", "completed" => 0)
  end

  it "stops an active device when another device report cannot be saved" do
    config(parallel: 2, devices: [
      { "host" => "192.0.2.10", "name" => "WLC-1", "platform" => "h3c" },
      { "host" => "192.0.2.11", "name" => "WLC-2", "platform" => "h3c" }
    ])
    started, blocked, closed = Queue.new, Queue.new, Queue.new
    factory = lambda do |device, _settings|
      connector = double("connector", platform: :h3c)
      allow(connector).to receive(:open) do |&operation|
        begin
          if device.fetch("host").end_with?("10")
            started.pop
            operation.call(WirelessFixtureSession.new(:h3c))
          else
            started << true
            blocked.pop
          end
        ensure
          closed << Thread.current
        end
      end
      connector
    end
    allow_any_instance_of(Wireless::CLI::Report).to receive(:write).and_raise(Errno::ENOSPC)
    status = Timeout.timeout(2) { run_cli("--quiet", "--json", factory: factory) }
    expect(status).to eq(2)
    expect(closed.size).to eq(2)
    expect(2.times.map { closed.pop }).to all(satisfy { |worker| !worker.alive? })
    summary = JSON.parse(@out.string)
    expect(summary).to include("status" => "incomplete", "completed" => 1, "report_error" => "Errno::ENOSPC")
    expect(summary.fetch("devices").first).to include("report_saved" => false)
  end

  it "uses the backup batch display and keeps JSON separate from terminal refreshes" do
    config
    @error.define_singleton_method(:tty?) { true }
    before = Thread.list
    factory = lambda do |_device, settings|
      expect(@error.string).to include("登录 1")
      expect(settings.fetch(:on_event)).to respond_to(:call)
      connector = double("connector", platform: :h3c)
      allow(connector).to receive(:open).and_yield(WirelessFixtureSession.new(:h3c))
      connector
    end
    expect(run_cli("--json", factory: factory)).to eq(0)
    expect(JSON.parse(@out.string).fetch("counts")).to eq("complete" => 1)
    expect(@error.string).to include("清单 1 台；本次 1 台；跳过 0 台；并发 4", "1/1 100%", "\e[2K", "批次结束：成功 1", "文本报告：")
    expect(Thread.list - before).to be_empty
  end

  it "prints failed devices and the final summary on stderr without private details" do
    config
    expect(run_cli(factory: ->(*) { raise IOError, "private diagnostic" })).to eq(1)
    expect(@out.string).to be_empty
    expect(@error.string).to include("192.0.2.10  未完成", "未完成分类：", "批次结束：成功 0，部分成功 0，失败 1，跳过 0")
    expect(@error.string).not_to include("private diagnostic", "已采集 1 台 |")
  end

  [ "配置：", "批次结束：" ].each do |stage|
    it "preserves collected results and records a display failure at #{stage}" do
      config
      writer = @error.method(:write)
      @error.define_singleton_method(:write) do |text|
        raise IOError, "private terminal error" if text.include?(stage)
        writer.call(text)
      end
      sessions = { "192.0.2.10" => WirelessFixtureSession.new(:h3c) }
      expect(run_cli("--json", factory: factory_for(sessions))).to eq(1)
      summary = JSON.parse(@out.string)
      expect(summary).to include("status" => "incomplete", "counts" => { "complete" => 1 }, "output_error" => { "host" => nil, "error_type" => "IOError" })
      expect(JSON.parse(File.read(File.join(summary.fetch("directory"), "summary.json")))).to eq(summary)
      expect(@out.string + @error.string).not_to include("private terminal error")
    end
  end

  [ Interrupt, RuntimeError ].each do |failure|
    it "preserves #{failure} exit status when stderr has permanently failed" do
      config
      @error.define_singleton_method(:write) { |*| raise IOError, "private terminal error" }
      factory = lambda do |_device, _settings|
        connector = double("connector", platform: :h3c)
        allow(connector).to receive(:open).and_yield(WirelessFixtureSession.new(:h3c))
        connector
      end
      executor = lambda do |devices, _parallel, &operation|
        operation.call(devices.first)
        raise failure, "private execution error"
      end
      expect(run_cli("--json", factory: factory, executor: executor)).to eq(failure == Interrupt ? 130 : 2)
      summary = JSON.parse(@out.string)
      expect(summary).to include("status" => failure == Interrupt ? "interrupted" : "incomplete")
      expect(summary.fetch("output_error")).to include("error_type" => "IOError")
      expect(summary.fetch("devices").first).to include("status" => "complete", "report_saved" => true)
      expect(@out.string).not_to include("private terminal error", "private execution error")
    end
  end

  [ false, true ].each do |interrupted|
    it "keeps acquired facts and exit priority when summary text publication fails (interrupted=#{interrupted})" do
      config
      calls = 0
      factory = lambda do |_device, _settings|
        calls += 1
      connector = double("connector", platform: :h3c)
      allow(connector).to receive(:open).and_yield(WirelessFixtureSession.new(:h3c))
      connector
      end
      executor = lambda do |items, _parallel, &operation|
        if interrupted
          operation.call(items.first)
          raise Interrupt
        end
        items.map(&operation)
      end
      original = File.method(:rename)
      allow(File).to receive(:rename) do |source, target|
        raise Errno::ENOSPC, "private-publication-detail" if target.end_with?("/summary.txt")
        original.call(source, target)
      end
      expect(run_cli("--json", factory: factory, executor: executor)).to eq(interrupted ? 130 : 2)
      saved_path = Dir[File.join(@directory, "reports/*/summary.json")].fetch(0)
      saved = JSON.parse(File.read(saved_path))
      expect(saved.fetch("status")).to eq(interrupted ? "interrupted" : "incomplete")
      expect(saved.fetch("devices")).to all(include("status" => "complete", "report_saved" => true))
      expect(calls).to eq(saved.fetch("completed"))
      expect(@out.string).to eq("")
      expect(@error.string).not_to include("private-publication-detail")
    end
  end

  it "rejects false filter lists before exposing config or creating reports" do
    config(names: false)
    instance = described_class.new(env: @env, out: @out, error: @error, input: StringIO.new, discovery: { directories: [ @directory ], home: @directory, cwd: @directory })
    expect(instance.run([ "--config", @config, "--env-file", File.join(@directory, "fixture.env"), "--show-config" ])).to eq(2)
    expect(@out.string).to eq("")
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end

  it "keeps independent batches when a runner is reused and preserves old reports after invalid input" do
    config
    factory = ->(*) { raise IOError, "fixture connection failure" }
    executor = ->(items, _parallel, &operation) { items.map(&operation) }
    instance = described_class.new(env: @env, out: @out, error: @error, input: StringIO.new, discovery: { directories: [ @directory ], home: @directory, cwd: @directory },
      connector_factory: factory, executor: executor)
    args = [ "--config", @config, "--env-file", File.join(@directory, "fixture.env"), "--json" ]
    summaries = 2.times.map do
      @out.truncate(0)
      @out.rewind
      expect(instance.run(args)).to eq(1)
      JSON.parse(@out.string)
    end
    expect(summaries.map { |summary| summary.fetch("completed") }).to eq([ 1, 1 ])
    expect(summaries.map { |summary| summary.fetch("directory") }.uniq.size).to eq(2)
    saved = summaries.to_h do |summary|
      path = File.join(summary.fetch("directory"), "summary.json")
      [ path, File.binread(path) ]
    end
    @out.truncate(0)
    @out.rewind
    expect(instance.run([ "--config", File.join(@directory, "missing.yml"), "--env-file", File.join(@directory, "fixture.env") ])).to eq(2)
    expect(@out.string).to eq("")
    saved.each { |path, bytes| expect(File.binread(path)).to eq(bytes) }
  end

  it "previews filtered inventory without credentials, connections or report creation" do
    config(devices: [ { "host" => "192.0.2.10", "name" => "WLC" }, { "host" => "192.0.2.11", "name" => "Spare" } ])
    @env.clear
    expect(run_cli("--plan", "--hosts", "192.0.2.0/24", "--exclude-name", "spare", "--json")).to eq(0)
    expect(JSON.parse(@out.string)).to eq([ { "host" => "192.0.2.10", "name" => "WLC", "model" => nil, "platform" => "h3c" } ])
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end

  it "applies CLI over process environment over YAML and keeps credentials out of public config" do
    config(parallel: 2)
    @env.merge!("WIRELESS_PARALLEL" => "invalid", "NC_DEVICE_PASSWORD" => "private-fixture")
    expect(run_cli("--show-config", "-p", "7")).to eq(0)
    expect(JSON.parse(@out.string)).to include("parallel" => 7)
    expect(@out.string).not_to include("private-fixture")
  end

  it "rejects invalid platforms, duplicate addresses and sensitive settings before connections" do
    [ { devices: [ { "host" => "192.0.2.10", "platform" => "cisco_nxos" } ] },
      { devices: [ { "host" => "2001:db8::1" }, { "host" => "2001:db8:0:0::1" } ] },
      { ssh: { "password" => "private-fixture" } }, { dimensions: [ "unknown" ] } ].each do |values|
      config(**values)
      expect(run_cli).to eq(2)
    end
    expect(Dir).not_to exist(File.join(@directory, "reports"))
    expect(@out.string + @error.string).not_to include("private-fixture")
  end

  it "rejects secrets and invalid identities in static devices before showing public config" do
    [ { "host" => "192.0.2.10", "password" => "private-device-secret" },
      { "host" => "invalid-host" }, { "host" => "192.0.2.10", "platform" => "unknown" } ].each do |device|
      config(devices: [ device ])
      expect(run_cli("--show-config")).to eq(2)
      expect(@out.string).to eq("")
    end
    expect(@error.string).not_to include("private-device-secret")
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end

  it "collects both platforms with sequential queries and saves structured facts privately" do
    config(devices: [ { "host" => "192.0.2.10" }, { "host" => "192.0.2.11", "platform" => "huawei" } ])
    sessions = { "192.0.2.10" => WirelessFixtureSession.new(:h3c), "192.0.2.11" => WirelessFixtureSession.new(:huawei) }
    expect(run_cli("--json", factory: factory_for(sessions))).to eq(0), @error.string
    summary = JSON.parse(@out.string)
    expect(summary).to include("counts" => { "complete" => 2 }, "completed" => 2)
    expect(sessions.fetch("192.0.2.10").commands).to eq([ "screen-length disable", "display wlan ap all verbose" ])
    expect(sessions.fetch("192.0.2.11").commands).to eq([ "screen-length 0 temporary", "display ap all" ])
    report = JSON.parse(File.read(Dir["#{summary.fetch('directory')}/devices/*.json"].first))
    expect(report.dig("snapshot", "dimensions", "access_points", "status")).to eq("complete")
    expect(File.stat("#{summary.fetch('directory')}/summary.json").mode & 0o777).to eq(0o600)
  end

  it "chooses Huawei defaults without requesting unsupported H3C dimensions" do
    config(dimensions: nil, devices: [ { "host" => "192.0.2.10", "platform" => "huawei" } ])
    session = WirelessFixtureSession.new(:huawei)
    expect(run_cli("--json", factory: factory_for({ "192.0.2.10" => session }))).to eq(0)
    expect(JSON.parse(@out.string).dig("devices", 0, "dimensions").keys).to contain_exactly("access_points", "clients", "collection")
  end

  it "does not mark a connector that never yields a session as complete" do
    config
    connector = double("connector", platform: :h3c, open: nil)
    expect(run_cli("--json", factory: ->(*) { connector })).to eq(1)
    summary = JSON.parse(@out.string)
    expect(summary.dig("devices", 0, "status")).to eq("failed")
    expect(summary.dig("devices", 0, "dimensions", "access_points", "issues")).to include("session_not_opened")
  end

  it "uses a frozen batch credential snapshot without mutating the caller environment" do
    config(devices: [ { "host" => "192.0.2.10" }, { "host" => "192.0.2.11" } ])
    path = File.join(@directory, "fixture.env")
    File.write(path, "NC_DEVICE_USERNAME=file-user\nNC_DEVICE_PASSWORD=batch-secret\n")
    @env = {}
    credentials = []
    factory = lambda do |device, settings|
      credentials << settings
      File.write(path, "NC_DEVICE_PASSWORD=changed-secret\n")
      connector = double("connector", platform: device.fetch("platform"))
      allow(connector).to receive(:open).and_yield(WirelessFixtureSession.new(:h3c))
      connector
    end
    executor = ->(items, _parallel, &operation) { items.map(&operation) }
    expect(run_cli("--json", factory: factory, executor: executor)).to eq(0), @error.string
    expect(credentials).to all(include(username: "file-user", password: "batch-secret"))
    expect(@env).to eq({})
    expect(@out.string + @error.string).not_to include("batch-secret", "changed-secret")
  end

  it "resolves platform-specific controller credentials before starting any target" do
    config(devices: [ { "host" => "192.0.2.10" }, { "host" => "192.0.2.11", "platform" => "huawei" } ])
    @env = { "NC_H3C_WIRELESS_USERNAME" => "h3c-user", "NC_H3C_WIRELESS_PASSWORD" => "controller-private" }
    expect(run_cli("--json")).to eq(2)
    expect(Dir).not_to exist(File.join(@directory, "reports"))
    expect(@out.string + @error.string).not_to include("controller-private")
  end

  it "keeps a failed controller separate from a complete sibling" do
    config(devices: [ { "host" => "192.0.2.10" }, { "host" => "192.0.2.11" } ])
    sessions = { "192.0.2.10" => WirelessFixtureSession.new(:h3c) }
    expect(run_cli("--json", factory: factory_for(sessions, failed: [ "192.0.2.11" ]))).to eq(1), @error.string
    expect(JSON.parse(@out.string).fetch("counts")).to eq("complete" => 1, "failed" => 1)
    expect(@out.string + @error.string).not_to include("private diagnostic")
  end

  it "retains pending controllers when scheduling fails" do
    config(devices: [ { "host" => "192.0.2.10" }, { "host" => "192.0.2.11" } ])
    executor = ->(items, _parallel, &operation) { operation.call(items.first); raise "private-scheduler" }
    expect(run_cli("--json", factory: factory_for({ "192.0.2.10" => WirelessFixtureSession.new(:h3c) }), executor: executor)).to eq(2)
    summary = JSON.parse(@out.string)
    expect(summary).to include("completed" => 1, "status" => "incomplete", "execution_error" => "RuntimeError")
    expect(summary.fetch("pending").map { |d| d.fetch("host") }).to eq([ "192.0.2.11" ])
    expect(@out.string + @error.string).not_to include("private-scheduler")
  end

  it "requires controller credentials before creating reports and reports no selected devices" do
    config
    @env.clear
    expect(run_cli).to eq(2)
    expect(Dir).not_to exist(File.join(@directory, "reports"))
    config(devices: [])
    expect(run_cli("--json")).to eq(1)
    expect(JSON.parse(@out.string)).to include("status" => "no_devices", "total" => 0)
  end

  it "collects explicit AP LLDP through the existing AP session contract" do
    config(dimensions: [ "lldp" ], ap_names: [ "AP-LAB" ])
    session = WirelessFixtureSession.new(:h3c, ap_body: "Total number of APs : 1\nAP name : AP-LAB\nAP ID : 7\nState : Run\n")
    now = Time.now.utc
    capture = CtxDriver::Capture.new(command: "display lldp neighbor-information verbose", body: "No LLDP neighbors\n", started_at: now, completed_at: now)
    reader = double("AP reader", read: { result: capture })
    ap_factory = lambda do |controller:, password:, username:|
      raise "Wrong controller" unless controller.equal?(session)
      raise "Wrong credentials" unless password == "ap-private" && username == "ap-user"
      reader
    end
    @env.merge!("WIRELESS_AP_PASSWORD" => "ap-private", "WIRELESS_AP_USERNAME" => "ap-user")
    expect(run_cli("--json", factory: factory_for({ "192.0.2.10" => session }), ap_session_factory: ap_factory)).to eq(0)
    summary = JSON.parse(@out.string)
    expect(summary.dig("devices", 0, "dimensions", "lldp", "status")).to eq("complete")
    expect(@out.string + @error.string).not_to include("ap-private")
  end
end
