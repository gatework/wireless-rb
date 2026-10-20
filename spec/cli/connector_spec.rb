# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli/collect"
require "wireless/ap_session"
require "rbconfig"

RSpec.describe Wireless::CLI::Connector do
  # 本地 PTY 经过真实连接器登录、逐命令回执、AP 登录与退出；不访问网络。
  class WirelessPtyTransport < Net::Connector::Transports::Pty
    def argv
      program = <<~'PROGRAM'
        $stdout.sync = true
        prompt = "<WLC>"
        print prompt
        while (line = gets)
          command = line.strip
          print line
          if command.start_with?("telnet ")
            print "Password:"
            gets
            prompt = "<AP-LAB>"
            print "\r\n#{prompt}"
            next
          end
          case command
          when "display wlan ap all verbose"
            print "Total number of APs : 1\r\nAP name : AP-LAB\r\nAP ID : 7\r\nState : Run\r\nIP address : 192.0.2.7\r\n"
          when "display ap all"
            print "ID MAC Name Group IP Type State STA Uptime\r\nTotal: 0\r\n"
          when "display lldp neighbor-information verbose"
            print "No LLDP neighbors\r\n"
          when "quit"
            prompt = "<WLC>"
          end
          print prompt
        end
      PROGRAM
      [ RbConfig.ruby, "-e", program ]
    end
  end

  it "supports H3C AP leases through an owned native controller session and closes it" do
    settings = { username: "fixture-user", command_timeout: 2, login_timeout: 2, host_key_policy: "strict" }
    transport = WirelessPtyTransport.new(Net::Connector::Configuration.new(host: "192.0.2.10", **settings))
    connector = described_class.new({ "host" => "192.0.2.10", "platform" => "h3c" }, settings.merge(transport: transport))
    snapshot = Wireless::Collector.new(ap_session_factory: ->(**args) { Wireless::ApSession.new(**args) }).collect(
      connector: connector, target: {}, platform: :h3c, dimensions: [ :lldp ], ap_credentials: { password: "fixture-ap" })
    expect(snapshot).to be_complete
    expect(snapshot.dimension(:lldp).evidence.first).to include(ap_name: "AP-LAB", attempted: true, status: :complete)
    expect(transport).to be_closed
  end

  it "opens the selected Huawei vendor and parses its native AP receipt" do
    settings = { username: "fixture-user", command_timeout: 2, login_timeout: 2, host_key_policy: "strict" }
    transport = WirelessPtyTransport.new(Net::Connector::Configuration.new(host: "192.0.2.11", **settings))
    connector = described_class.new({ "host" => "192.0.2.11", "platform" => "huawei" }, settings.merge(transport: transport))
    snapshot = Wireless::Collector.new.collect(connector: connector, target: {}, platform: :huawei, dimensions: [ :access_points ])
    expect(snapshot).to be_complete
    expect(snapshot.records(:access_points)).to be_empty
    expect(transport).to be_closed
  end
end
