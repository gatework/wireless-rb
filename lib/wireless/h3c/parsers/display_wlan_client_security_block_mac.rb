# frozen_string_literal: true

require_relative "../parser"

module Wireless
  module H3c
    module Parsers
      # 解析明确的阻断客户端记录及空列表证据。
      class DisplayWlanClientSecurityBlockMac < Parser
        private

        # 解释当前命令记录，保留不完整行诊断。
        def parse_text(text, complete:)
          records, issues = [], []
          text.lines("\n").each_with_index do |line, index|
            row = line.strip
            next if row.empty? || /\A[-=]+\z/.match?(row) || /\A(?:No blocked clients|MAC address\b.*|(?:Client )?block list|Blocked clients|Total.*:\s*\d+)\z/i.match?(row)
            if (match = /\A((?:[0-9a-f]{4}-){2}[0-9a-f]{4}|(?:[0-9a-f]{2}:){5}[0-9a-f]{2})\s*(.*?)\z/i.match(row))
              records << { mac_address: Fields.mac_address(match[1]), reason: match[2] }
            else
              issues << { code: :unrecognized_line, line: index + 1 }
            end
          end
          total = reported_total(text, noun: "(?:blocked clients|clients)", issues: issues)
          total = 0 if /\ANo blocked clients\s*$/i.match?(text.strip)
          Fields.result(records, issues: issues, complete: complete, total: total, identity: [ :mac_address ])
        end
      end
    end
  end
end
