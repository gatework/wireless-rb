# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/h3c/parsers/display_current_configuration"

RSpec.describe Wireless::H3c::Parsers::DisplayCurrentConfiguration do
  let(:parser) { described_class.new }

  it "retains controller identity and AP-group broadcast policy in their own scopes" do
    source = <<~CLI
      wlan global-configuration
       region-code-lock enable
       nas-id controller-01
      #
      wlan ap-group LAB
       rrop anti-bmc network ipv4-and-ipv6-simple enable
       rrop anti-bmc default-action deny
      #
      return
    CLI
    result = parser.parse(source, complete: true)
    expect(result).to be_complete
    expect(result.records.first[:global_settings]).to include(region_code_lock: true, nas_id: "controller-01")
    expect(result.records.first[:ap_groups].first[:configuration]).to include(
      rrop_anti_bmc: { network: { mode: "ipv4-and-ipv6-simple", enabled: true }, default_action: "deny" })
    expect(parser.cursor.unparsed_content).to eq("")

    disabled = parser.parse(source.sub("region-code-lock enable", "undo region-code-lock enable")
      .sub("rrop anti-bmc network", "undo rrop anti-bmc network"), complete: true)
    expect(disabled).to be_complete
    expect(disabled.records.first[:global_settings][:region_code_lock]).to be(false)
    expect(disabled.records.first[:ap_groups].first.dig(:configuration, :rrop_anti_bmc, :network, :enabled)).to be(false)
  end

  it "keeps misplaced controller identity and unknown broadcast policy syntax unresolved" do
    result = parser.parse("wlan service-template EAP\n nas-id misplaced\n#\nwlan ap-group LAB\n rrop anti-bmc network future-mode enable\n#\nreturn\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first[:global_settings]).not_to have_key(:nas_id)
    expect(result.records.first[:ap_groups].first[:configuration]).not_to have_key(:rrop_anti_bmc)
    expect(result.issues.map { |issue| issue[:line] }).to eq([ 2, 5 ])
  end

  it "associates final template data with its exact original block while excluding secrets from results" do
    source = "wlan service-template GUEST\r\n ssid Guest Network\r\n\r\n preshared-key pass-phrase cipher PRIVATE-PSK\r\n service-template enable\r\n#\r\nreturn\r\n"
    result = parser.parse(source, complete: true)
    capture = parser.cursor.captures_for([ :service_templates, 0 ]).fetch(0)

    expect(result).to be_complete
    expect(capture.data).to eq(result.records.fetch(0)[:service_templates].fetch(0))
    expect(capture.data[:authentication_type]).to eq("psk")
    expect(capture.content).to eq(source.split("#\r\n").first)
    expect(capture.line_range).to eq(1..5)
    expect(capture).to be_complete
    expect(parser.cursor.states).to eq(%i[parsed parsed ignored parsed parsed ignored ignored])
    expect(parser.cursor.position).to eq(7)
    expect(parser.cursor.unparsed_content).to eq("")
    expect(result.to_h.keys).to eq(%i[status records issues])
    expect([ result, parser, capture, parser.blocks ].map(&:inspect).join).not_to include("PRIVATE-PSK")
    expect(result.to_h.inspect).not_to include("PRIVATE-PSK")
    expect { capture.data[:configuration][:has_preshared_key] = false }.to raise_error(FrozenError)
    expect { result.records.fetch(0)[:service_templates].fetch(0)[:ssid].replace("Changed") }.to raise_error(FrozenError)
    expect(capture.data).not_to equal(result.records.fetch(0)[:service_templates].fetch(0))
    expect(capture.data[:ssid]).to eq("Guest Network")
  end

  it "retains model and radio ownership and source ranges across nested blocks and CR boundaries" do
    source = [
      "wlan ap-group LAB", " ap-model WA6530", "  radio 1", "   service-template EAP vlan 120",
      "  radio 2", "   radio disable", "#", "wlan ap AP-1 model WA6530",
      " gigabitethernet 1", "  description AP uplink", "return"
    ].join("\r")
    result = parser.parse(source, complete: true)
    model_path = [ :ap_groups, 0, :model_profiles, "WA6530" ]
    model = parser.cursor.captures_for(model_path).fetch(0)
    radio = parser.cursor.captures_for(model_path + [ :radios, "1" ]).fetch(0)
    ethernet = parser.cursor.captures_for([ :access_points, "AP-1", :ethernet_ports, "gigabitethernet 1" ]).fetch(0)

    expect(result).to be_complete
    expect(model.line_range).to eq(2..6)
    expect(radio.line_range).to eq(3..4)
    expect(radio.content).to eq("  radio 1\r   service-template EAP vlan 120\r")
    expect(radio.data[:service_templates]).to eq([ { name: "EAP", vlan_id: 120 } ])
    expect(model.data.dig(:radios, "2", :enabled)).to be(false)
    expect(ethernet.data).to eq(description: "AP uplink")
    expect(parser.cursor.content).to eq(source)
  end

  it "captures each repeated scope when its own block completes" do
    source = <<~CLI
      wlan global-configuration
       auto-ap enable
       radio 5g
        radio enable
      #
      wlan global-configuration
       undo auto-ap enable
       radio 5g
        radio disable
      #
      return
    CLI
    result = parser.parse(source, complete: true)
    globals = parser.cursor.captures_for([ :global_settings ])
    radios = parser.cursor.captures_for([ :global_settings, :band_defaults, "5g" ])

    expect(result).to be_complete
    expect(result.records.fetch(0).dig(:global_settings, :auto_ap)).to be(false)
    expect(globals.map { |capture| capture.data[:auto_ap] }).to eq([ true, false ])
    expect(radios.map { |capture| capture.data[:enabled] }).to eq([ true, false ])
    expect(globals.map(&:line_range)).to eq([ 1..4, 6..9 ])
    expect(globals.first.content).to include(" auto-ap enable\n")
    expect(globals.first.content).not_to include("undo auto-ap enable")
    expect(globals.last.content).to include(" undo auto-ap enable\n")
  end

  it "retains the existing unnamed virtual group record and source path" do
    source = "wlan virtual-ap-group\n auto-ap enable\n#\nreturn\n"
    result = parser.parse(source, complete: true)
    capture = parser.cursor.captures_for([ :global_settings, :virtual_ap_group, nil ]).fetch(0)

    expect(result).to be_complete
    expect(result.records.fetch(0).dig(:global_settings, :virtual_ap_group)).to eq(nil => { auto_ap: true })
    expect(capture.data).to eq(auto_ap: true)
    expect(capture.content).to eq("wlan virtual-ap-group\n auto-ap enable\n")
    expect(capture.line_range).to eq(1..2)
  end

  it "keeps unknown subtrees unresolved instead of applying their children to a recognized parent" do
    source = <<~CLI
      wlan service-template EAP
       ssid Corporate
       future-authentication
        ssid Incorrect inherited value
       vlan 9999
       service-template enable
      #
      return
    CLI
    result = parser.parse(source, complete: true)
    capture = parser.cursor.captures_for([ :service_templates, 0 ]).fetch(0)

    expect(result.status).to eq(:partial)
    expect(capture.data).to include(ssid: "Corporate", vlan_id: nil, enabled: true)
    expect(capture).not_to be_complete
    expect(capture.content).to include("future-authentication\n", "ssid Incorrect inherited value\n", "vlan 9999\n")
    expect(parser.cursor.states).to eq(%i[parsed parsed unsupported unsupported invalid parsed ignored ignored])
    expect(parser.cursor.unparsed_lines.map(&:number)).to eq([ 3, 4, 5 ])
    expect(result.issues).to include({ code: :unrecognized_wireless_configuration, line: 3 },
      { code: :unrecognized_wireless_configuration, line: 4 }, { code: :invalid_configuration_line, line: 5 })
  end

  it "does not capture duplicate entities or their rejected child data as successfully parsed" do
    source = "wlan service-template EAP\n ssid Original\n#\nwlan service-template EAP\n ssid Duplicate\n#\nreturn\n"
    result = parser.parse(source, complete: true)

    expect(result.status).to eq(:partial)
    expect(parser.cursor.captures_for([ :service_templates, 0 ]).size).to eq(1)
    expect(parser.cursor.state(3)).to eq(:invalid)
    expect(parser.cursor.state(4)).to eq(:unsupported)
    expect(result.records.fetch(0)[:service_templates].fetch(0)[:ssid]).to eq("Original")
  end

  it "tracks standalone global fields and excluded device blocks with fresh state per invocation" do
    source = "sysname WLC\ninterface Vlan-interface1\n ip address 192.0.2.1 24\n#\nwlan static-blacklist mac-address 0200-0000-0001\nreturn\n"
    result = parser.parse(source, complete: true)
    previous = parser.cursor

    expect(result).to be_complete
    expect(previous.captures_for([ :global_settings, :hostname ]).fetch(0).data).to eq("WLC")
    expect(previous.captures_for([ :blacklist, 0 ]).fetch(0).data[:mac_address]).to eq("02:00:00:00:00:01")
    expect(previous.states).to eq(%i[parsed ignored ignored ignored parsed ignored])
    expect(parser.parse("Unrecognized command", complete: true).status).to eq(:unsupported)
    expect(parser.cursor).to be_nil
    expect(parser.blocks).to eq([])
    expect(parser.parse("return\n", complete: true)).to be_complete
    expect(parser.cursor).not_to equal(previous)
    expect(parser.cursor.captures).to eq([])
    expect(previous.captures.size).to eq(2)
  end

  it "does not promote misplaced global declarations from an AP into another configuration scope" do
    source = <<~CLI
      sysname WLC
      wlan ap AP-1 model WA6530
       sysname FORGED
       wlan service-template FORGED
        ssid Incorrect
       radio 1
        service-template EAP vlan 120
      return
    CLI
    result = parser.parse(source, complete: true)
    config = result.records.fetch(0)

    expect(result.status).to eq(:partial)
    expect(config.dig(:global_settings, :hostname)).to eq("WLC")
    expect(config[:service_templates]).to eq([])
    expect(config.dig(:access_points, "AP-1", :radios, "1", :service_templates)).to eq([ { name: "EAP", vlan_id: 120 } ])
    expect(parser.cursor.states).to eq(%i[parsed parsed unsupported unsupported unsupported parsed parsed ignored])
    expect(parser.cursor.captures_for([ :global_settings, :hostname ]).map(&:data)).to eq([ "WLC" ])
    expect(parser.cursor.captures_for([ :service_templates, 0 ])).to be_empty
  end

  it "does not join separate CR-delimited lines when identifying a command error" do
    source = "wlan ap AP-1 model WA6530\r description Error: maintenance\r map-configuration command-file\rreturn\r"
    result = parser.parse(source, complete: true)

    expect(result).to be_complete
    expect(parser.cursor.content).to eq(source)
    expect(result.records.first.dig(:access_points, "AP-1", :map_configuration)).to eq("command-file")
    expect(parser.parse("Error: Unknown command\r", complete: true).status).to eq(:unsupported)
  end
  it "keeps fixed MAC authentication credentials out of facts and source captures" do
    %w[simple cipher].each do |storage|
      [ "account demo password #{storage} SYNTHETIC-SECRET", "password #{storage} SYNTHETIC-SECRET", "account demo" ].each do |suffix|
        [ "mac-authentication user-name-format fixed #{suffix}\nreturn\n",
          "wlan service-template LAB\n mac-authentication user-name-format fixed #{suffix}\nreturn\n" ].each do |source|
          result = parser.parse(source, complete: true)
          expect(result).to be_complete
          settings = source.start_with?("wlan") ? result.records.first[:service_templates].first[:configuration] : result.records.first[:global_settings]
          expect(settings[:mac_authentication_user_name_format]).to eq("fixed")
          expect(settings[:mac_authentication_has_password]).to eq(suffix.include?("password"))
          expect([ result.to_h, parser.cursor.captures.map(&:data), Wireless::Config.new.parse(source, complete: true).to_h ].inspect).not_to include("SYNTHETIC-SECRET")
          expect(parser.cursor.content).to eq(source)
        end
      end
    end
  end

  it "retains MAC address username formats and rejects unknown format options" do
    result = parser.parse("mac-authentication user-name-format mac-address with-hyphen uppercase\nreturn\n", complete: true)
    expect(result).to be_complete
    expect(result.records.first[:global_settings][:mac_authentication_user_name_format]).to eq("mac-address with-hyphen uppercase")
    expect(parser.parse("mac-authentication user-name-format future SECRET\nreturn\n", complete: true).status).to eq(:partial)
  end
  it "keeps command error phrases in ordinary configuration values" do
    [ "Unknown command", "Invalid input", "Unrecognized command", "Wrong parameter", "Error: command" ].each do |ssid|
      source = "sysname AC\nwlan service-template office\n ssid #{ssid}\nreturn\n"
      result = parser.parse(source, complete: true)
      expect(result).to be_complete
      expect(result.records.first[:service_templates].first[:ssid]).to eq(ssid)
      expect(Wireless::RuntimeParser.new(platform: :h3c).parse(:configuration, source, complete: true)).to be_complete
    end
    expect(parser.parse("% Unrecognized command found at '^' position.\r", complete: true).status).to eq(:unsupported)
    expect(parser.parse("Error: Unknown command\n", complete: true).status).to eq(:unsupported)
  end

  it "keeps paginated or terminal-damaged configuration partial at every source position" do
    [ "--More--\nsysname AC\nreturn\n", "sysname AC\n--More--\nreturn\n",
      "sysname AC\nwlan service-template office\n ssid Off--More--ice\nreturn\n",
      "sysname AC\n\e[31mignored terminal text\nreturn\n" ].each do |source|
      result = parser.parse(source, complete: true)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :incomplete_configuration))
    end
  end

  it "retains damaged source and marks its enclosing template capture incomplete" do
    source = "wlan service-template office\n ssid Office\n --More--\n service-template enable\nreturn\n"
    result = parser.parse(source, complete: true)
    capture = parser.cursor.captures_for([ :service_templates, 0 ]).fetch(0)
    expect(result.status).to eq(:partial)
    expect(capture).not_to be_complete
    expect(capture.content).to include(" --More--\n")
    expect(capture.data).to include(ssid: "Office", enabled: true)
    expect(parser.cursor.state(2)).to eq(:invalid)
  end

  it "preserves raw controls and incomplete capture state without accepting a damaged SSID" do
    [ "\b", "\x7f", "\e7" ].each do |control|
      source = "wlan service-template office\r\n ssid Off#{control}ice\r\n service-template enable\r\nreturn\r\n"
      result = parser.parse(source, complete: true)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(code: :incomplete_configuration, line: 2)
      expect(result.records.first[:service_templates].first[:ssid]).to be_nil
      expect(parser.cursor.content).to eq(source)
      expect(parser.cursor.captures_for([ :service_templates, 0 ]).first).not_to be_complete
    end
  end

  it "isolates banner contents from configuration, command errors, and pagination diagnostics" do
    source = "header legal %\nUnknown command\n--More--\nwlan service-template forged\n ssid FORGED\n%\nsysname AC\nreturn\n"
    result = parser.parse(source, complete: true)
    expect(result).to be_complete
    expect(result.records.first[:service_templates]).to be_empty
    expect(result.records.first[:global_settings][:hostname]).to eq("AC")
    expect(parser.parse("header legal %\nnot closed\n", complete: true)).not_to be_complete
    expect(parser.document.issues).to include(code: :incomplete_banner)
  end
end
