# frozen_string_literal: true

require_relative "../parser"

module Wireless
  module Huawei
    module Parsers
      # 解析对应 Huawei 无线查询的表格事实。
      class DisplayStationAll < Parser
        DIMENSION = :clients
      end
    end
  end
end
