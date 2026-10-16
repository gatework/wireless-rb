# frozen_string_literal: true

require "date"
require_relative "../parser"

module Wireless
  module H3c
    module Parsers
      # 解析冲突事件，不虚构设备时间戳的年份或时区。
      class DisplayWlanStatisticsClientIpConflict < Parser
        private

        # 解释当前命令记录，保留不完整行诊断。
        def parse_text(text, complete:)
          records, issues = [], []
          header = false
          text.lines.each_with_index do |line, index|
            row = line.strip
            next if row.empty? || /\A[-=]+\z/.match?(row)
            if /\AIP\s+New-MAC\/APID\s+Old-MAC\/APID\s+Time\z/i.match?(row)
              header = true
              next
            end
            begin
              records << parse_row(row)
            rescue ArgumentError, IPAddr::Error
              issues << { code: :invalid_row, line: index + 1 }
            end
          end
          # 本命令没有总数尾行；采集完整且只有表头时表示空表。
          total = 0 if header && records.empty? && issues.empty?
          Fields.result(records, issues: issues, complete: complete, total: total,
            identity: %i[ip_address new_mac_address new_ap_id old_mac_address old_ap_id occurred_at])
        end

        # 按当前命令的身份与字段布局解析单条表格记录。
        def parse_row(row)
          match = /\A(\S+)\s+(\S+)\/(\d+)\s+(\S+)\/(\d+)\s+(\d{2}-\d{2} \d{2}:\d{2}:\d{2})\z/.match(row)
          raise ArgumentError, "Invalid conflict row" unless match

          month, day, hour, minute, second = match[6].split(/[- :]/).map(&:to_i)
          raise ArgumentError, "Invalid conflict time" unless Date.valid_date?(2000, month, day) && hour < 24 && minute < 60 && second < 60

          { ip_address: Fields.ip(match[1]), new_mac_address: Fields.mac(match[2]), new_ap_id: Fields.integer(match[3]).to_s,
            old_mac_address: Fields.mac(match[4]), old_ap_id: Fields.integer(match[5]).to_s, occurred_at: match[6] }
        end
      end
    end
  end
end
