# frozen_string_literal: true

require_relative "parser_registry"
require_relative "observation"

module Wireless
  # 将平台配置结果封装为领域观测。
  class Configuration
    # 按当前平台和型号选择无线配置策略。
    def initialize(platform: :h3c, model: nil)
      @profile = ParserRegistry.fetch(platform, model: model)
    end

    # 解析控制器配置，将事实封装为无线配置观测。
    def parse(content, complete: false)
      result = @profile.parse(:configuration, content, complete: complete)
      Observation.new(name: :configuration, **result.to_h)
    rescue ArgumentError
      Observation.new(name: :configuration, status: :failed, issues: [ { code: :invalid_output } ])
    end
  end
end
