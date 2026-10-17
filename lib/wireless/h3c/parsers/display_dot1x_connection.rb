# frozen_string_literal: true

require_relative "../record_parser"
require_relative "../authentication"

module Wireless
  module H3c
    module Parsers
      # 解析 display dot1x connection 报告的会话。
      class DisplayDot1xConnection < RecordParser
        include Authentication
      end
    end
  end
end
