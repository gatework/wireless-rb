# frozen_string_literal: true

require_relative "../verbose_parser"

module Wireless
  module H3c
    module Parsers
      # 单条回显同时包含 AP 清单及其嵌套 Radio 清单。
      class DisplayWlanApAllVerbose < VerboseParser
        AP_FIELDS = { "ap id" => :ap_id, "ap group name" => :group_name, "state" => :operational_status,
          "model" => :model, "mac address" => :mac_address, "ip address" => :management_ip,
          "serial id" => :serial, "s/w version" => :os_version, "client count" => :client_count,
          "number of clients" => :client_count, "online clients" => :client_count, "online time" => :uptime_seconds }.freeze
        RADIO_FIELDS = { "admin state" => :admin_status, "state" => :admin_status, "radio type" => :protocol,
          "type" => :protocol, "channel" => :channel, "channel usage(%)" => :utilization,
          "channel usage" => :utilization, "noise floor" => :noise_dbm, "channel bandwidth" => :channel_width,
          "operating bandwidth" => :channel_width }.freeze
        AP_DETAILS = [ "backup type", "ready-for-switchover", "system uptime", "region code", "region code lock",
          "udp control port number", "udp data port number", "h/w version", "boot version", "usb state", "power level",
          "power info", "poe status", "description", "priority", "echo interval", "echo count", "keepalive interval",
          "discovery-response wait-time", "statistics report interval", "fragment size (data)", "fragment size (control)",
          "mac type", "tunnel mode", "discovery type", "retransmission count", "retransmission interval", "firmware upgrade",
          "sent control packets", "received control packets", "echo requests", "lost echo responses", "average echo delay",
          "last reboot reason", "last reboot reason (ac check)", "latest ip address", "current ac ip", "tunnel down reason",
          "connection count", "backup ipv4", "backup ipv6", "ctrl-tunnel encryption", "ctrl-tunnel encryption state",
          "data-tunnel encryption", "data-tunnel encryption state", "led mode", "remote configuration", "energysaving level",
          "ap type", "map file", "forwarding mode", "ble mode", "capwap data-tunnel status" ].freeze
        RADIO_DETAILS = [ "basic bssid", "bssid", "antenna type", "client dot11ac-only", "client dot11n-only",
          "secondary channel offset", "secondary channel mode", "short gi for 20mhz", "short gi for 40mhz",
          "short gi for 80mhz", "short gi for 160mhz", "mimo", "green-energy-management", "a-msdu", "a-mpdu", "ldpc", "stbc",
          "max power", "operational rate", "distance", "ani", "fragmentation threshold", "beacon interval", "protection threshold",
          "long retry threshold", "short retry threshold", "frame aging time in cache", "protection mode", "mu-txbf", "su-txbf",
          "continuous mode", "client dot11ax-only", "ofdma random access rus", "he ofdma random access rus", "channel width set",
          "dl-ofdma", "ul-ofdma", "ul-mu-mimo", "bss-color", "twt negotiation", "radar-detect switch", "ht protection mode",
          "atf", "preamble type", "operational vht-mcs set", "mandatory", "supported", "multicast", "operational ht mcs set",
          "disabled", "operational he-mcs set" ].freeze

        private

        # 解释当前命令记录，保留不完整行诊断。
        def parse_text(text, complete:)
          access_points, radios, issues = [], [], []
          ap = radio = nil
          tokens(text, issues).each do |label, raw, line|
            if label == "ap name"
              ap = { name: raw }
              access_points << ap
              radio = nil
            elsif (match = /\Aradio (\d+)\z/.match(label))
              radio = { ap_name: ap&.fetch(:name), radio_id: match[1] }
              radios << radio
            else
              owner = radio && RADIO_FIELDS.key?(label) ? radio : ap
              mapping = owner.equal?(radio) && radio ? RADIO_FIELDS : AP_FIELDS
              details = AP_DETAILS.include?(label) ? ap : RADIO_DETAILS.include?(label) ? radio : nil
              assign_field(owner, mapping, label, raw, issues, line, details: details)
            end
          end
          invalid = access_points.reject { |record| !record[:name].nil? && !record[:name].strip.empty? }
          issues << { code: :invalid_identity } if invalid.any?
          valid_aps = access_points - invalid
          issues << { code: :duplicate_identity } if CtxParser::Records.new(valid_aps, identity: [ :name ]).duplicates?
          radios.reject! do |record|
            missing = record[:ap_name].nil? || record[:ap_name].strip.empty?
            issues << { code: :invalid_identity } if missing
            missing
          end
          total = count(text, "APs")
          issues << { code: :count_mismatch, expected: total, parsed: valid_aps.size } if total && total != valid_aps.size
          # AP 总数证明共享命令的覆盖范围，不代表 Radio 数量。
          radio_total = total && total == valid_aps.size ? radios.size : nil
          CtxParser::ResultSet.new(results: {
            access_points: Fields.result(valid_aps, issues: issues.dup, complete: complete, total: total, identity: [ :name ]),
            radios: Fields.result(radios, issues: issues.dup, complete: complete, total: radio_total, identity: %i[ap_name radio_id])
          })
        end
      end
    end
  end
end
