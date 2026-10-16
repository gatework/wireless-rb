# frozen_string_literal: true

require_relative "../authentication_parser"

module Wireless
  module H3c
    module Parsers
      # 解析 display mac-authentication connection 报告的会话。
      class DisplayMacAuthenticationConnection < AuthenticationParser
      end
    end
  end
end
