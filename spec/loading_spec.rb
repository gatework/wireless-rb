# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "json"

RSpec.describe "Standalone wireless command parsers" do
  it "loads the public API without loading a transport library" do
    script = <<~RUBY
      module Kernel
        alias wireless_original_require require
        def require(name)
          raise LoadError, "Transport library requested" if name.start_with?("net/connector")
          wireless_original_require(name)
        end
      end
      require "wireless"
      abort "Transport activated" if defined?(Net::Connector::Base) || $LOADED_FEATURES.any? { |path| path.end_with?("/net/connector.rb") }
      parsed = Wireless::Configuration.new.parse("sysname WLC\nreturn\n", complete: true)
      abort "Configuration unavailable" unless parsed.complete?
      abort "Collector unavailable" unless Wireless::Collector.new
    RUBY
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup",
      "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(status).to be_success, stderr
  end

  parsers = {
    "display_wlan_ap_all_verbose" => [ "DisplayWlanApAllVerbose", "Total number of APs : 0\n" ],
    "display_wlan_bss_all_verbose" => [ "DisplayWlanBssAllVerbose", "Current BSS number : 0\n" ],
    "display_wlan_client_verbose" => [ "DisplayWlanClientVerbose", "Total number of clients : 0\n" ],
    "display_dot1x_connection" => [ "DisplayDot1xConnection", "Total number of connections : 0\n" ],
    "display_mac_authentication_connection" => [ "DisplayMacAuthenticationConnection", "Total number of connections : 0\n" ],
    "display_wlan_client_security_block_mac" => [ "DisplayWlanClientSecurityBlockMac", "No blocked clients\n" ],
    "display_current_configuration" => [ "DisplayCurrentConfiguration", "sysname WLC\nreturn\n" ],
    "display_lldp_neighbor_information_verbose" => [ "DisplayLldpNeighborInformationVerbose", "No LLDP neighbors\n" ]
  }

    parsers.each do |file, (constant, output)|
      it "loads and parses #{file} without Rails, a collector or a database" do
        script = <<~RUBY
          require "json"
          abort "Unexpected application dependency" if defined?(Rails) || defined?(ActiveRecord) || defined?(ActiveSupport) || defined?(Motor)
          parser = Object.const_get(ARGV.fetch(0))
          result = parser.parse(STDIN.read, complete: true)
          puts JSON.generate(status: result.status, issues: result.issues)
        RUBY
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup",
          "-I", File.expand_path("../lib", __dir__),
          "-r", "wireless/h3c/parsers/#{file}", "-e", script, "Wireless::H3c::Parsers::#{constant}", stdin_data: output)

        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to include("status" => "complete", "issues" => [])
      end
    end
end
