# frozen_string_literal: true

require_relative "fields"
require_relative "observation"

module Wireless
  # 仅支持有证据的 Huawei 表格格式，区分不支持维度与空清单。
  class HuaweiRuntime
    # 解析支持的 Huawei AP 或客户端汇总，其余维度标记为不支持。
    def parse(name, text, complete:)
      unless %i[access_points clients].include?(name)
        return Observation.new(name: name, status: :unsupported, issues: [ { code: :unsupported_platform_dimension } ])
      end
      records, issues = [], []
      header = false
      total = nil
      text.lines.each_with_index do |line, index|
        row = line.strip
        next if row.empty? || /\A[-=]+\z/.match?(row)
        if (match = /\ATotal\s*:\s*(\d+)\z/i.match(row))
          total = match[1].to_i
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
      Observation.new(name: name, **result.to_h)
    end

    private

    # 归一化控制器报告的单条 AP 记录。
    def ap(columns)
      raise ArgumentError, "Invalid AP row" unless columns.size == 9
      id, mac, name, group, ip, model, state, clients, uptime = columns
      { ap_id: Fields.integer(id).to_s, mac_address: Fields.mac(mac), name: name, group_name: group,
        management_ip: Fields.ip(Fields.value(ip)), model: model, operational_status: Fields.online_status(state),
        client_count: Fields.integer(clients), uptime_seconds: Fields.duration(Fields.value(uptime)) }
    end

    # 归一化控制器报告的单条无线客户端记录。
    def client(columns)
      raise ArgumentError, "Invalid station row" unless columns.size == 15
      mac, ap_id, ap_name, radio_wlan, band, protocol, rates, rssi, vlan, ip, ssid, state, ipv6, _ac_id, uptime = columns
      raise ArgumentError, "Invalid station identity" unless /\A\d+\/\d+\z/.match?(radio_wlan)
      rx, tx = Fields.rates(rates)
      signal = Fields.number(Fields.value(rssi), unit: "dBm")
      { client_mac: Fields.mac(mac), ap_id: Fields.integer(ap_id).to_s, ap_name: ap_name, radio_id: radio_wlan.split("/").first,
        band: Fields.band(band), protocol: protocol, rx_rate_mbps: rx, tx_rate_mbps: tx, signal_dbm: signal == 0 ? nil : signal,
        vlan: Fields.integer(vlan, max: 4094), client_ip: Fields.ip(Fields.value(ip)), ssid: ssid, operational_status: state,
        client_ipv6: Fields.ip(Fields.value(ipv6)), uptime_seconds: Fields.duration(Fields.value(uptime)) }
    end
  end
end
