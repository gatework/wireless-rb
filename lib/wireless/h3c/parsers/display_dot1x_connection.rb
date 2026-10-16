# frozen_string_literal: true

require_relative "../authentication_parser"

module Wireless
  module H3c
    module Parsers
      # 解析 display dot1x connection 报告的会话。
      class DisplayDot1xConnection < AuthenticationParser
      end
    end
  end
end
