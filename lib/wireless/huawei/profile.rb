# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "parsers/display_ap_all"
require_relative "parsers/display_station_all"

module Wireless
  module Huawei
    # Huawei 查询通过相同命令声明和参数协议进入采集与解析。
    class Profile < CtxParser::Profile
      DECLARATIONS = CtxParser::Commands.new([
        { dimensions: [ :access_points ], command: "display ap all", parser: Parsers::DisplayApAll },
        { dimensions: [ :clients ], command: "display station all", parser: Parsers::DisplayStationAll }
      ])
      COMMANDS = DECLARATIONS.by_dimension
      PARSERS = DECLARATIONS.parsers

      # 本平台使用临时会话分页设置。
      def preparation_command = "screen-length 0 temporary"
    end
  end
end
