# frozen_string_literal: true

require "ctx_parser/parser"
require_relative "command_output"

module Wireless
  module H3c
    # 命令专用解析前，先应用 H3C 响应边界。
    class Parser < CtxParser::Parser
      include CommandOutput
    end
  end
end
