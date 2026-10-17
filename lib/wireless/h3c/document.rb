# frozen_string_literal: true

require "ctx_parser/document"
require "ctx_parser/banner"
require_relative "../terminal"

module Wireless
  module H3c
    # 横幅仅含文本；分页及终端控制残留使配置证据不完整。
    class Document < CtxParser::Document
      protected

      # 先隔离横幅，再分类影响完整性的终端残留。
      def classify(line)
        @banner ||= CtxParser::Banner.new
        return :ignored if @banner.consume(line.text)

        if Terminal.invalid_output?(line.raw)
          issues << { code: :incomplete_configuration, line: line.number }
          return :ignored
        end
        super
      end

      # 未闭合横幅不能成为完整配置证据。
      def finish
        issues.each { |issue| cursor.mark(issue.fetch(:line) - 1, state: :invalid) }
        issues << { code: :incomplete_banner } if @banner&.open?
      end
    end
  end
end
