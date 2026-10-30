# frozen_string_literal: true

require "ctx_parser/registry"
require_relative "h3c/profile"
require_relative "huawei/profile"

module Wireless
  # 平台与维度目录均从命令声明派生，采集、快照及 CLI 共用同一允许范围。
  PROFILES = { h3c: H3c::Profile, huawei: Huawei::Profile }.freeze
  PLATFORM_ALIASES = { h3c_wireless: :h3c }.freeze
  SUPPORTED_PLATFORMS = (PROFILES.keys + PLATFORM_ALIASES.keys).map { |platform| platform.to_s.freeze }.freeze
  SUPPORTED_DIMENSIONS = PROFILES.values.flat_map { |profile| profile::DECLARATIONS.by_dimension.keys }.uniq.freeze

  # 将 h3c_wireless 视为 H3C 无线平台策略的连接器别名。
  ParserRegistry = CtxParser::Registry.new(profiles: PROFILES, aliases: PLATFORM_ALIASES)
end
