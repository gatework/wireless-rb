# frozen_string_literal: true

require "ctx_parser/registry"
require_relative "h3c/profile"
require_relative "huawei/profile"

module Wireless
  # 将 h3c_wireless 视为 H3C 无线平台策略的连接器别名。
  ParserRegistry = CtxParser::Registry.new(profiles: { h3c: H3c::Profile, huawei: Huawei::Profile }, aliases: { h3c_wireless: :h3c })
end
