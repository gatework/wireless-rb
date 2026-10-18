# frozen_string_literal: true

require_relative "../record_parser"
require_relative "../authentication_fields"

module Wireless
  module H3c
    module Parsers
      # 解析 display dot1x connection 报告的会话。
      class DisplayDot1xConnection < RecordParser
        include AuthenticationFields
      end
    end
  end
end
