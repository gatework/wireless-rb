# frozen_string_literal: true

require "ctx_parser/input"
require "ctx_parser/values"
require "ctx_parser/result"
require "ctx_parser/records"

module Wireless
  # 归一化厂商单位与身份，不将未知测量强制转换为零。
  module Fields
    extend self

    # 校验来源文本，仅按请求调整编码或换行形式。
    def text(content, newlines: :lf)
      raise ArgumentError, "Invalid wireless output" unless content.is_a?(String)
      begin
        CtxParser::Input.text(content, encoding: :utf8, newlines: newlines)
      rescue ArgumentError, EncodingError
        raise ArgumentError, "Invalid wireless encoding"
      end
    end

    # 归一化 CLI 缺失占位符，不转换为已知的空事实。
    def value(raw)
      string = raw.to_s.strip
      string unless string.empty? || /\A(?:N\/A|--|-|Not configured|Not supported)\z/i.match?(string)
    end

    # 归一化 MAC 地址，拒绝格式错误的输入。
    def mac_address(raw)
      CtxParser::Values.mac_address(raw)
    rescue ArgumentError
      raise ArgumentError, "Invalid wireless MAC"
    end

    # 归一化 IP 主机地址，拒绝无效无线身份数据。
    def ip_address(raw)
      CtxParser::Values.ip_address(raw)
    rescue IPAddr::Error
      raise
    rescue ArgumentError
      raise ArgumentError, "Invalid wireless host address"
    end

    # 解析十进制整数，并校验声明的边界。
    def integer(raw, max: nil)
      CtxParser::Values.integer(raw, max: max)
    rescue CtxParser::Values::OutOfRange
      raise ArgumentError, "Wireless integer out of range"
    rescue ArgumentError
      raise ArgumentError, "Invalid wireless integer"
    end

    # VLAN 业务身份限定为 1..4094，未声明的可选绑定保持未知。
    def vlan_id(raw)
      vlan = integer(raw, max: 4094)
      raise ArgumentError, "Invalid wireless VLAN" if vlan && vlan.zero?

      vlan
    end

    # 解析数值测量，不将未知文本转换为零。
    def number(raw, unit: nil)
      return if raw.nil?
      match = /\A(-?\d+(?:\.\d+)?)\s*(?:#{Regexp.escape(unit.to_s)})?\z/i.match(raw.to_s)
      raise ArgumentError, "Invalid wireless number" unless match

      measurement = Float(match[1])
      raise ArgumentError, "Invalid wireless number" unless measurement.finite?

      measurement
    end

    # 将支持的时长格式转换为秒，并校验各时间分量。
    def duration_seconds(raw)
      return if raw.nil?
      if /\A\d+:\d{2}:\d{2}:\d{2}\z/.match?(raw)
        days, hours, minutes, seconds = raw.split(":").map(&:to_i)
        raise ArgumentError, "Invalid wireless duration" unless hours < 24 && minutes < 60 && seconds < 60
        return days * 86_400 + hours * 3600 + minutes * 60 + seconds
      end
      parts = raw.scan(/(\d+)\s*(days?|hours?|minutes?|seconds?|[dhms])\b/i)
      remainder = raw.gsub(/\d+\s*(?:days?|hours?|minutes?|seconds?|[dhms])\b/i, "").delete(" :,")
      raise ArgumentError, "Invalid wireless duration" if parts.empty? || !remainder.empty?
      parts.sum { |amount, unit| amount.to_i * { "d" => 86_400, "h" => 3600, "m" => 60, "s" => 1 }.fetch(unit[0].downcase) }
    end

    # 将成对收发速率转换为每秒兆比特。
    def rates_mbps(raw)
      return [ nil, nil ] if raw.nil?
      match = /\A(\d+(?:\.\d+)?)\s*\/\s*(\d+(?:\.\d+)?)\s*([kmgt]?bps)?\z/i.match(raw)
      raise ArgumentError, "Invalid wireless rates" unless match
      multiplier = { "bps" => 0.000001, "kbps" => 0.001, "mbps" => 1, "gbps" => 1000, "tbps" => 1_000_000 }.fetch((match[3] || "Mbps").downcase)
      [ match[1], match[2] ].map do |value|
        rate = Float(value) * multiplier
        raise ArgumentError, "Invalid wireless rates" unless rate.finite?

        rate
      end
    end

    # 解析明确无线信道；自动选择仍保持未知。
    def channel(raw)
      return if raw.nil? || /\Aauto\z/i.match?(raw.to_s)
      match = /\A(\d+)(?:\s*\([^\n]*\))?\z/.match(raw.to_s)
      raise ArgumentError, "Invalid wireless channel" unless match
      number = integer(match[1], max: 233)
      number if number.positive?
    end

    # 将支持的 MHz 回显归一化为正数信道宽度。
    def channel_width_mhz(raw)
      match = /\A(\d+)\s*(?:MHz)?\z/i.match(raw.to_s)
      match[1].to_i if match && match[1].to_i.positive?
    end

    # 信道编号在不同频段重叠，频段须由明确标签或专属 PHY 证据确定。
    def frequency_band(hint)
      bands = []
      bands << "6GHz" if /(?<![\d.])6\s*g(?:hz)?\b/i.match?(hint.to_s)
      bands << "5GHz" if /(?<![\d.])5\s*g(?:hz)?\b/i.match?(hint.to_s)
      bands << "2.4GHz" if /(?<![\d.])2\.4\s*g(?:hz)?\b|802\.11[bg](?:\b|\/)/i.match?(hint.to_s)
      bands.first if bands.one?
    end

    # 归一化已知在线、离线标签，同时保留未识别状态。
    def online_status(raw)
      return "online" if /\A(?:run|running|online|normal|nor|up)\z/i.match?(raw.to_s)
      return "offline" if /\A(?:idle|fault|offline|down)\z/i.match?(raw.to_s)
      raw
    end

    # 身份冲突降低完整性；保留首条记录仅用于部分投影。
    def result(records, issues:, complete:, total: nil, identity:)
      issues << { code: :count_mismatch, expected: total, parsed: records.size } if total && total != records.size
      issues << { code: :missing_completeness_evidence } unless complete && (total || records.any?)
      identities = CtxParser::Records.new(records, identity: identity)
      identities.duplicate_row_count.times { issues << { code: :duplicate_identity } }
      records = identities.first_occurrences.dup
      status = issues.empty? ? :complete : records.empty? ? :failed : :partial
      CtxParser::Result.new(status: status, records: records, issues: issues.uniq)
    end
  end
end
