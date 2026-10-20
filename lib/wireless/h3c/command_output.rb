# frozen_string_literal: true

require_relative "../fields"
require_relative "../terminal"

module Wireless
  module H3c
    # 复用 H3C 输入校验；各命令实现 parse_text，配置解析保留原始换行。
    module CommandOutput
      private

      # 解释当前命令回显，保留不支持或格式错误的证据。
      def parse_output(text, complete:)
        text = Fields.text(text, newlines: output_newlines)
        if Terminal.unsupported?(text)
          return CtxParser::Result.new(status: :unsupported, issues: [ { code: :unsupported_command } ])
        end

        if (issue = terminal_issue(text))
          return CtxParser::Result.new(status: :partial, issues: [ issue ])
        end

        @field_assignments = {}.compare_by_identity
        parse_text(text, complete: complete)
      rescue ArgumentError, IPAddr::InvalidAddressError
        CtxParser::Result.new(status: :failed, issues: [ { code: :invalid_output } ])
      end

      # 校验每条总数声明，不能用第一条匹配掩盖矛盾或损坏的尾行。
      def reported_total(text, noun:, issues:, continuation_lines: nil, auxiliary_nouns: nil)
        prefix = /\A(?:Total\b|Number of (?:#{noun})\b|Current BSS number\b)/i
        totals = []
        text.each_line("\n").with_index do |line, index|
          row = line.strip
          next if continuation_lines&.key?(index + 1)
          next unless prefix.match?(row)
          # 辅助统计只接受命令明确声明的名称与合法计数，不能替代记录总数。
          next if auxiliary_nouns && /\ATotal(?: number of)? (?:#{auxiliary_nouns})\s*:\s*\d+\s*\z/i.match?(row)
          if (match = /\A(?:Total(?: number of)?(?:\s+(?:#{noun}))?|Number of (?:#{noun})|Current BSS number)\s*:\s*(\d+)\s*\z/i.match(row))
            totals << match[1].to_i
          else
            issues << { code: :invalid_total, line: index + 1 }
          end
        end
        issues << { code: :conflicting_total } if totals.uniq.size > 1
        totals.first
      end

      # 同一字段允许等价重复；发生歧义后删除事实，后续声明不能恢复它。
      def assign_value(record, field, value, issues, line, identity: field)
        assignments = (@field_assignments[record] ||= {})
        if (previous = assignments[identity])
          if previous[:conflicted] || previous[:value] != value
            record.delete(field)
            issues << { code: :conflicting_field, line: line, first_line: previous[:line] }
            previous[:conflicted] = true
            return
          end
        else
          assignments[identity] = { value: value, line: line }
        end
        record[field] = value
      end

      # 运行回显受损时不能继续信任任何字段。
      def terminal_issue(text) = Terminal.issue(text)

      # 声明当前命令解析器所需的换行归一化方式。
      def output_newlines = :lf
    end
  end
end
