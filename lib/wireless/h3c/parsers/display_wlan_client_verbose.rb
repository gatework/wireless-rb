# frozen_string_literal: true

require_relative "../session_parser"

module Wireless
  module H3c
    module Parsers
      # 解析客户端会话，区分相对 RSSI 与实测 dBm。
      class DisplayWlanClientVerbose < SessionParser
        MAPPING = COMMON_FIELDS.merge("mac address" => :client_mac, "ipv4 address" => :client_ip,
          "ip address" => :client_ip, "ipv6 address" => :client_ipv6, "username" => :username,
          "channel" => :channel, "frequency band" => :band, "state" => :operational_status, "status" => :operational_status,
          "wireless mode" => :protocol, "channel bandwidth" => :channel_width, "sm power save mode" => :power_save,
          "sm power save" => :power_save, "qos mode" => :qos, "online time" => :uptime_seconds,
          "authentication method" => :auth_method, "security mode" => :security, "akm mode" => :akm,
          "cipher suite" => :cipher).freeze
        DETAILS = [ "authorization car", "authorization acl id", "authorization user profile", "key derivation",
          "forwarding policy name", "ft status", "sae pwe method", "authorization user group name", "authorization dynamic acl name",
          "mlo status", "user authentication mode", "wpa3 status", "pmf status", "block ack", "supported vht-mcs set",
          "supported ht mcs set", "supported rates", "supported he-mcs set", "sleep count", "short gi for 40mhz",
          "short gi for 80mhz", "short gi for 160/80+80mhz", "stbc tx capability", "beamformee sts capability",
          "number of sounding dimensions", "su beamformee capability", "mu beamformee capability", "5g 40and80mhz channel bandwidth",
          "5g 160mhz channel bandwidth", "5g 80+80mhz channel bandwidth", "20/40 bss coexistence management",
          "2.4g 40mhz channel bandwidth", "short gi for 20mhz", "stbc rx capability", "ldpc rx capability",
          "ofdma random access rus", "twt scheduled", "listen interval", "aid", "roam status", "btm mode", "radio slice(last effecive)", "speed" ].freeze
        IDENTITY = [ :client_mac ].freeze
        COUNT = "clients".freeze

        private

        # 归一化成对客户端速率，区分相对 RSSI 与实测 dBm。
        def assign_session_field(record, label, raw, issues, line)
          case label
          when "rx/tx rate"
            safely(issues, line) { record[:rx_rate_mbps], record[:tx_rate_mbps] = Fields.rates(raw) }
          when "rssi"
            safely(issues, line) do
              signal = Fields.number(raw, unit: "dBm")
              record[:signal_dbm] = signal if signal&.negative?
              record[:rssi] = signal.round if signal&.positive?
            end
          else
            super
          end
        end
      end
    end
  end
end
