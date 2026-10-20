# frozen_string_literal: true

require "ctx_parser/immutable"

module Wireless
  # 保存单个维度的事实与安全诊断；默认检查不展示记录正文。
  Observation = Data.define(:name, :status, :records, :issues, :evidence, :started_at, :completed_at) do
    # 冻结单个维度的记录、状态及诊断元数据。
    def initialize(name:, status:, records: [], issues: [], evidence: [], started_at: nil, completed_at: nil)
      raise ArgumentError, "Wireless observation name must be a symbol" unless name.is_a?(Symbol)
      raise ArgumentError, "Invalid wireless observation status" unless %i[complete partial failed unsupported not_requested].include?(status)
      raise ArgumentError, "Wireless records must be hashes" unless records.is_a?(Array) && records.all? { |record| record.is_a?(Hash) }
      raise ArgumentError, "Unavailable wireless observation has records" if %i[failed unsupported not_requested].include?(status) && records.any?

      unless [ started_at, completed_at ].all? { |time| time.nil? || time.is_a?(Time) }
        raise ArgumentError, "Wireless observation timestamps must be Time values or nil"
      end

      super(name: name, status: status, records: CtxParser::Immutable.copy(records),
        issues: CtxParser::Immutable.copy(issues), evidence: CtxParser::Immutable.copy(evidence),
        started_at: started_at&.dup&.freeze, completed_at: completed_at&.dup&.freeze)
    end

    # 判断所有已选事实是否都有完整证据支持。
    def complete? = status == :complete
    # 判断证据不完整时是否仍保留可用事实。
    def partial? = status == :partial
    # 判断当前观测是否包含完整或部分可用证据。
    def available? = complete? || partial?
    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class.name} name=#{name} status=#{status} records=#{records.size}>"
    alias to_s inspect
    # PP 默认展开 Data 成员，显式沿用脱敏展示。
    def pretty_print(printer) = printer.text(inspect)
  end
end
