# frozen_string_literal: true

require "ctx_parser/immutable"
require_relative "observation"
require_relative "parser_registry"

module Wireless
  # 携带调用方提供的设备身份，不引入独立资产模型。
  Snapshot = Data.define(:target, :observations, :observed_at) do
    DIMENSIONS = (SUPPORTED_DIMENSIONS + [ :collection ]).freeze

    # 冻结设备身份、观测结果与采样时间。
    def initialize(target:, observations:, observed_at: Time.now.utc)
      unless target.is_a?(Hash) && observations.is_a?(Hash) && observations.any? &&
          observations.all? { |name, value| DIMENSIONS.include?(name) && value.is_a?(Observation) && value.name == name } &&
          observed_at.is_a?(Time)
        raise ArgumentError, "Invalid wireless snapshot"
      end
      super(target: CtxParser::Immutable.copy(target), observations: observations.to_h { |name, value| [ name, value ] }.freeze,
        observed_at: observed_at.dup.freeze)
    end

    # 返回所选观测，或明确的未请求占位结果。
    def observation(name)
      raise ArgumentError, "Unknown wireless dimension" unless DIMENSIONS.include?(name)
      observations.fetch(name) { Observation.new(name: name, status: :not_requested) }
    end
    # 返回请求观测维度的记录。
    def records(name) = observation(name).records

    # 报告格式独立于 Ruby 成员命名，已有离线证据继续使用 dimensions。
    def to_h = super.except(:observations).merge(dimensions: observations)

    # 判断所有已选事实是否都有完整证据支持。
    def complete?
      selected = observations.values.reject { |value| value.status == :not_requested }
      selected.any? && selected.all?(&:complete?)
    end

    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class.name} complete=#{complete?}>"
    alias to_s inspect
    # PP 默认展开 Data 成员，显式沿用脱敏展示。
    def pretty_print(printer) = printer.text(inspect)
  end
end
