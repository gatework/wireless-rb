# frozen_string_literal: true

require_relative "parser_registry"
require_relative "fields"
require_relative "huawei_runtime"
require_relative "observation"

module Wireless
  # 将平台解析结果映射为无线维度，同时保留 Huawei 解析入口。
  class RuntimeParser
    # 保留型号选择信息，供每次解析所选平台使用。
    def initialize(model: nil)
      @model = model
    end

    # 使用传入平台及保留的型号选择解析单个无线维度。
    def parse(name, content, platform: "h3c", complete: false)
      parse_many([ name ], content, platform: platform, complete: complete).fetch(name)
    end

    # 共享命令仅解析一次，再投影各请求维度。
    def parse_many(names, content, platform: "h3c", complete: false)
      text = Fields.text(content)
      if H3c::Parser::UNSUPPORTED.match?(text)
        return unavailable(names, :unsupported, :unsupported_command)
      end
      if platform.to_s == "huawei"
        return names.to_h { |name| [ name, HuaweiRuntime.new.parse(name, text, complete: complete) ] }
      end

      profile = ParserRegistry.fetch(platform, model: @model)
      supported, unsupported = names.partition { |name| profile.commands.key?(name) }
      results = supported.empty? ? {} : profile.parse_many(supported, text, complete: complete)
      observations = results.to_h { |name, result| [ name, Observation.new(name: name, **result.to_h) ] }
      observations.merge(unavailable(unsupported, :unsupported, :unsupported_platform_dimension))
    rescue ArgumentError, IPAddr::InvalidAddressError
      unavailable(names, :failed, :invalid_output)
    end

    private

    # 构建明确不可用的观测，不虚构成功的空结果。
    def unavailable(names, status, code)
      names.to_h { |name| [ name, Observation.new(name: name, status: status, issues: [ { code: code } ]) ] }
    end
  end
end
