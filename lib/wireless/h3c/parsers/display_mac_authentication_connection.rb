# frozen_string_literal: true

require_relative "../record_parser"
require_relative "../authentication_fields"

module Wireless
  module H3c
    module Parsers
      # 解析 display mac-authentication connection 报告的会话。
      class DisplayMacAuthenticationConnection < RecordParser
        include AuthenticationFields
      end
    end
  end
end
