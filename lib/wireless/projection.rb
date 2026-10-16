# frozen_string_literal: true

require "ctx_parser/immutable"

module Wireless
  # 资产应用具有独立结果；父对象缺失不使已采集事实失效。
  Projection = Data.define(:dimensions) do
    # 冻结各维度的资产应用结果。
    def initialize(dimensions: {})
      super(dimensions: CtxParser::Immutable.copy(dimensions))
    end

    # 判断所有请求的资产投影是否均已完成。
    def complete? = dimensions.values.all? { |entry| entry.fetch(:status) == :complete }
  end
end
