# frozen_string_literal: true

require_relative "../fields"
require_relative "../terminal"
require "ctx_parser/parser"

module Wireless
  module Huawei
    # 仅支持有证据的 Huawei 表格格式，区分不支持维度与空清单。
    class Parser < CtxParser::Parser
      private

      # 标准解析边界负责参数校验，子类只选择对应命令的维度。
      def parse_output(text, complete:)
        name = self.class::DIMENSION
        text = Fields.text(text)
        if Terminal.unsupported?(text)
          return CtxParser::Result.new(status: :unsupported, issues: [ { code: :unsupported_command } ])
        end
        if (issue = Terminal.issue(text))
          return CtxParser::Result.new(status: :partial, issues: [ issue ])
        end
        records, issues = [], []
        header = false
        total = nil
        text.lines.each_with_index do |line, index|
          row = line.strip
          next if row.empty? || /\A[-=]+\z/.match?(row)
          if (match = /\ATotal\s*:\s*(\d+)\z/i.match(row))
            reported = match[1].to_i
            issues << { code: :conflicting_total, line: index + 1 } if total && total != reported
            total ||= reported
          elsif name == :access_points ? /\AID\s+MAC\s+Name\s+Group\s+IP\s+Type\s+State\s+STA\s+Uptime\b/i.match?(row) : /\ASTA MAC\s+AP ID\s+Ap name\s+Rf\/WLAN\b/i.match?(row)
            header = true
          elsif /\ATotal AP information:|\A(?:nor|fault|idle|stdby)\s*:/i.match?(row)
            next
          elsif !header
            issues << { code: :missing_header, line: index + 1 }
          else
            begin
              records << (name == :access_points ? ap(row.split) : client(row.split))
            rescue ArgumentError, IPAddr::InvalidAddressError
              issues << { code: :invalid_row, line: index + 1 }
            end
          end
        end
        issues << { code: :missing_header } unless header
        result = Fields.result(records, issues: issues, complete: complete, total: total, identity: [ name == :access_points ? :name : :client_mac ])
        result
      rescue ArgumentError, IPAddr::InvalidAddressError
        CtxParser::Result.new(status: :failed, issues: [ { code: :invalid_output } ])
      end

      private

      # IPv6 专用列不能接受合法但属于 IPv4 的地址。
      def ipv6_address(raw)
        address = Fields.ip_address(raw)
        raise ArgumentError, "Invalid station IPv6 address" if address && !address.include?(":")
        address
      end

      # 归一化控制器报告的单条 AP 记录。
      def ap(columns)
        raise ArgumentError, "Invalid AP row" unless columns.size == 9
        id, mac, name, group, ip, model, state, clients, uptime = columns
        { ap_id: Fields.integer(id).to_s, mac_address: Fields.mac_address(mac), name: name, group_name: group,
          management_ip: Fields.ip_address(Fields.value(ip)), model: model, operational_status: Fields.online_status(state),
          client_count: Fields.integer(clients), uptime_seconds: Fields.duration_seconds(Fields.value(uptime)) }
      end

      # 归一化控制器报告的单条无线客户端记录。
      def client(columns)
        raise ArgumentError, "Invalid station row" unless columns.size == 15
        mac, ap_id, ap_name, radio_wlan, band, protocol, rates, rssi, vlan, ip, ssid, state, ipv6, _ac_id, uptime = columns
        raise ArgumentError, "Invalid station identity" unless /\A\d+\/\d+\z/.match?(radio_wlan)
        rx, tx = Fields.rates_mbps(rates)
        signal = Fields.number(Fields.value(rssi), unit: "dBm")
        { client_mac: Fields.mac_address(mac), ap_id: Fields.integer(ap_id).to_s, ap_name: ap_name, radio_id: radio_wlan.split("/").first,
          band: Fields.frequency_band(band), protocol: protocol, rx_rate_mbps: rx, tx_rate_mbps: tx, signal_dbm: signal == 0 ? nil : signal,
          vlan: Fields.integer(vlan, max: 4094), client_ip: Fields.ip_address(Fields.value(ip)), ssid: ssid, operational_status: state,
          client_ipv6: ipv6_address(Fields.value(ipv6)), uptime_seconds: Fields.duration_seconds(Fields.value(uptime)) }
      end
    end
  end
end
