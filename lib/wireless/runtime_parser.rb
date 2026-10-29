# frozen_string_literal: true

require_relative "parser_registry"
require_relative "fields"
require_relative "observation"

module Wireless
  # 按平台解析无线观测，统一保留各维度的完整性与诊断。
  class RuntimeParser
    # 构造时固定平台及型号策略，所有解析使用同一 Profile。
    def initialize(platform:, model: nil)
      raise ArgumentError, "Device model must be text" unless model.nil? || model.is_a?(String)

      @profile = ParserRegistry.fetch(platform, model: model)
    end

    # 按已固定的平台策略解析单个无线维度。
    def parse(name, content, complete: false, command: nil)
      parse_many([ name ], content, complete: complete, command: command).fetch(name)
    end

    # 共享命令仅解析一次，再投影各请求维度。
    def parse_many(names, content, complete: false, command: nil)
      unless names.is_a?(Array) && names.any? && names.all? { |name| SUPPORTED_DIMENSIONS.include?(name) } && names.uniq == names
        raise ArgumentError, "Dimensions must be unique supported symbols"
      end
      raise ArgumentError, "Completeness must be boolean" unless [ true, false ].include?(complete)
      raise ArgumentError, "Parser input must be text" unless content.is_a?(String)

      profile = @profile
      begin
        text = Fields.text(content, newlines: :preserve)
      rescue ArgumentError
        return unavailable_observations(names, :failed, :invalid_output)
      end
      if Terminal.unsupported?(text)
        return unavailable_observations(names, :unsupported, :unsupported_command)
      end
      supported, unsupported = names.partition { |name| profile.commands.key?(name) }
      results = supported.empty? ? {} : profile.parse_many(supported, text, complete: complete, command: command)
      observations = results.to_h { |name, result| [ name, Observation.new(name: name, **result.to_h) ] }
      observations.merge(unavailable_observations(unsupported, :unsupported, :unsupported_platform_dimension))
    end

    private

    # 构建明确不可用的观测，不虚构成功的空结果。
    def unavailable_observations(names, status, code)
      names.to_h { |name| [ name, Observation.new(name: name, status: status, issues: [ { code: code } ]) ] }
    end
  end
end
