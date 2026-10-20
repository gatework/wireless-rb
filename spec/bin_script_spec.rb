# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "yaml"
require "json"

RSpec.describe "Direct wireless script" do
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @project = File.join(directory, "wireless")
      FileUtils.mkdir_p(File.join(@project, "bin"))
      File.symlink(File.expand_path("../lib", __dir__), File.join(@project, "lib"))
      source = File.expand_path("../bin/wireless.rb", __dir__)
      FileUtils.cp(source, File.join(@project, "bin")) if File.file?(source)
      example.run
    end
  end

  def invoke(*args, cwd: @directory, env: {})
    cleared = ENV.keys.grep(/\A(?:WIRELESS_|NC_|ND_)/).to_h { |key| [ key, nil ] }
    Open3.capture3(cleared.merge("HOME" => @directory, "XDG_CONFIG_HOME" => File.join(@directory, "config"), **env), RbConfig.ruby, File.join(@project, "bin/wireless.rb"), *args, chdir: cwd)
  end

  it "runs collection options directly and reads script directory env and YAML from another cwd" do
    File.write(File.join(@project, "bin/.env"), "NC_PARALLEL=7\nNC_HOST_KEY_POLICY=accept_new\nNC_KNOWN_HOSTS=./keys\nNC_DEVICE_PASSWORD='private-fixture'\n")
    File.write(File.join(@project, "bin/wireless.yml"), YAML.dump("devices" => [ { "host" => "192.0.2.10" } ], "directory" => "reports"))
    stdout, stderr, status = invoke("--show-config")
    expect(status).to be_success, stderr
    values = JSON.parse(stdout)
    expect(values).to include("parallel" => 7, "directory" => File.join(@project, "bin/reports"))
    expect(values.fetch("ssh")).to include("host_key_policy" => "accept_new", "known_hosts" => File.join(@project, "bin/keys"))
    expect(stdout).not_to include("private-fixture")
  end

  it "initializes the user configuration directory without writing into the source tree" do
    stdout, stderr, status = invoke("--init", "--non-interactive")
    expect(status).to be_success, stderr
    expect(File).to exist(File.join(@directory, "config/net-connector/wireless.yml"))
    expect(File).to exist(File.join(@directory, "config/net-connector/.env"))
    expect(Dir.children(@directory).sort).to eq(%w[config wireless])
    expect(Dir.children(File.join(@project, "bin"))).to eq([ "wireless.rb" ])
    expect(stdout).to include("未连接设备")
  end

  it "keeps an explicit process config relative to the original invocation directory" do
    File.write(File.join(@directory, "selected.yml"), YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
    stdout, stderr, status = invoke("--plan", "--json", env: { "WIRELESS_CONFIG" => "selected.yml" })
    expect(status).to be_success, stderr
    expect(JSON.parse(stdout).first.fetch("host")).to eq("192.0.2.10")
  end
end
