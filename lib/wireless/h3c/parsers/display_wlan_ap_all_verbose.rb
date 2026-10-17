# frozen_string_literal: true

require_relative "../record_parser"

module Wireless
  module H3c
    module Parsers
      # 单条回显同时包含 AP 清单及其嵌套 Radio 清单。
      class DisplayWlanApAllVerbose < RecordParser
        AP_FIELDS = { "ap id" => :ap_id, "ap group name" => :group_name, "state" => :operational_status,
          "model" => :model, "mac address" => :mac_address, "ip address" => :management_ip,
          "serial id" => :serial, "s/w version" => :os_version, "client count" => :client_count,
          "number of clients" => :client_count, "online clients" => :client_count, "online time" => :online_seconds, "system uptime" => :uptime_seconds }.freeze
        RADIO_FIELDS = { "admin state" => :admin_status, "state" => :admin_status, "radio type" => :protocol,
          "type" => :protocol, "channel" => :channel, "channel usage(%)" => :utilization,
          "channel usage" => :utilization, "noise floor" => :noise_dbm, "channel bandwidth" => :channel_width,
          "operating bandwidth" => :channel_width, "channel band-width" => :channel_width }.freeze
        RADIO_SECTIONS = { "operational vht-mcs set" => :vht_mcs, "operational ht mcs set" => :ht_mcs,
          "operational he-mcs set" => :he_mcs, "operational rate" => :operational_rates }.freeze
        SECTION_FIELDS = %w[mandatory supported multicast disabled].freeze
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
        RADIO_DETAILS = [ "basic bssid", "base bssid", "bssid", "antenna type", "client dot11ac-only", "client dot11n-only",
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
          aps_with_radio_evidence = {}.compare_by_identity
          ap = radio = nil
          section = nil
          section_indent = nil
          read_fields(text, issues).each do |label, raw, line, indent|
            if label == "ap name"
              ap = { name: raw }
              access_points << ap
              radio = nil
              section = nil
            elsif (match = /\Aradio (\d+)\z/.match(label))
              radio = { ap_name: ap&.fetch(:name), radio_id: match[1] }
              radios << radio
              aps_with_radio_evidence[ap] = true if ap
              section = nil
            else
              if radio && RADIO_SECTIONS.key?(label)
                section = RADIO_SECTIONS.fetch(label)
                section_indent = indent
                # 空标题本身不属于测量；其子标签在相应速率或 MCS 集合内拥有身份。
                assign_value(radio[:details] ||= {}, label.tr(" -", "__").to_sym, raw, issues, line)
                next
              end
              section = nil if section && indent <= section_indent
              if radio && section && SECTION_FIELDS.include?(label)
                details = radio[:details] ||= {}
                assign_value(details[section] ||= {}, label.to_sym, raw, issues, line)
                next
              end
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
          total = record_count(text, "APs", issues)
          issues << { code: :count_mismatch, expected: total, parsed: valid_aps.size } if total && total != valid_aps.size
          # AP 总数只证明 AP 范围；未报告 Radio 的 AP 不能证明其 Radio 清单为空。
          radio_issues = issues.dup
          valid_aps.each do |record|
            radio_issues << { code: :missing_radio_evidence, ap_name: record[:name] } unless aps_with_radio_evidence.key?(record)
          end
          radio_total = total == 0 && valid_aps.empty? ? 0 : nil
          CtxParser::Results.new(by_dimension: {
            access_points: Fields.result(valid_aps, issues: issues.dup, complete: complete, total: total, identity: [ :name ]),
            radios: Fields.result(radios, issues: radio_issues, complete: complete, total: radio_total, identity: %i[ap_name radio_id])
          })
        end
      end
    end
  end
end
