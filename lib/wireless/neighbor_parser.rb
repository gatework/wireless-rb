# frozen_string_literal: true

require_relative "parser_registry"
require_relative "observation"

module Wireless
  # AP 身份由采集上下文提供；LLDP 解析器只读取响应报告的端点。
  class NeighborParser
    # 按 AP 型号选择邻居回显解析器。
    def initialize(platform: :h3c, model: nil)
      @profile = ParserRegistry.fetch(platform, model: model)
    end

    # 解析 LLDP 端点，并关联采集上下文提供的 AP 身份。
    def parse(content, ap_name:, complete: false)
      raise ArgumentError, "Missing AP name" unless ap_name.is_a?(String) && !ap_name.strip.empty?
      raise ArgumentError, "Parser input must be text" unless content.is_a?(String)
      raise ArgumentError, "Completeness must be boolean" unless [ true, false ].include?(complete)

      unless @profile.commands.key?(:lldp)
        return Observation.new(name: :lldp, status: :unsupported, issues: [ { code: :unsupported_platform_dimension } ])
      end

      result = @profile.parse(:lldp, content, complete: complete)
      records = result.records.map { |record| record.merge(ap_name: ap_name) }
      Observation.new(name: :lldp, **result.to_h.merge(records: records))
    end
  end
end
