# frozen_string_literal: true

require "ctx_parser/banner"

module Wireless
  # 分页及终端编辑控制会破坏事实边界；正常换行和制表符仍是来源文本。
  module Terminal
    INVALID = /--[ \t]*More[ \t]*--|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/i
    private_constant :INVALID

    UNSUPPORTED = /(?:\A|(?<=[\r\n]))[ \t]*(?:%[ \t]*)?(?:Unrecognized command\b|Wrong parameter\b|Invalid (?:input|command)\b|Unknown command\b|Error:[^\r\n]*\bcommand\b)[^\r\n]*/i

    private_constant :UNSUPPORTED

    # 错误响应须独占来源行；横幅正文不是设备命令诊断。
    def self.unsupported?(text)
      banner = CtxParser::Banner.new
      text.split(/\r\n?|\n/).any? { |line| !banner.consume(line.strip) && UNSUPPORTED.match?(line) }
    end

    # 在字段清理之前检测终端残留，避免将编辑后的文本接受为事实。
    def self.invalid_output?(text) = INVALID.match?(text)

    # 运行回显无可恢复的来源树，返回首个受损来源行的安全诊断。
    def self.issue(text)
      return unless invalid_output?(text)

      line = text.split(/\r\n?|\n/).find_index { |source| invalid_output?(source) }
      { code: :invalid_terminal_output, line: line + 1 }
    end
  end
end
