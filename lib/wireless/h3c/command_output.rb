# frozen_string_literal: true

require_relative "../fields"

module Wireless
  module H3c
    # 复用 H3C 输入校验；各命令实现 parse_text，配置解析保留原始换行。
    module CommandOutput
      UNSUPPORTED = /(?:Unrecognized command|Wrong parameter|Invalid (?:input|command)|Unknown command|Error:[^\r\n]*command)/i

      private

      # 解释当前命令回显，保留不支持或格式错误的证据。
      def parse_output(text, complete:)
        text = Fields.text(text, newlines: output_newlines)
        if UNSUPPORTED.match?(text)
          return CtxParser::Result.new(status: :unsupported, issues: [ { code: :unsupported_command } ])
        end

        parse_text(text, complete: complete)
      rescue ArgumentError, IPAddr::InvalidAddressError
        CtxParser::Result.new(status: :failed, issues: [ { code: :invalid_output } ])
      end

      # 声明当前命令解析器所需的换行归一化方式。
      def output_newlines = :lf
    end
  end
end
