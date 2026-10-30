# frozen_string_literal: true

require "forwardable"
require "ctx_runner/snapshot"
require_relative "observation"
require_relative "parser_registry"

module Wireless
  # 领域组合公共快照，身份、维度、时间及采集结论共用同一契约。
  class Snapshot
    include CtxRunner::Document::Value
    extend Forwardable
    def_delegators :@snapshot, :target, :observations, :observed_at, :issues, :collection_status,
      :observation, :records, :complete?, :same_target?
    DIMENSIONS = SUPPORTED_DIMENSIONS

    def initialize(target:, observations:, observed_at: Time.now.utc, issues: [])
      @snapshot = CtxRunner::Snapshot.new(target: target, observations: observations, observed_at: observed_at,
        names: SUPPORTED_DIMENSIONS, issues: issues)
      freeze
    end

    def to_h = @snapshot.to_h
    def inspect = "#<#{self.class.name} collection_status=#{collection_status}>"
    alias to_s inspect
    def pretty_print(printer) = printer.text(inspect)
  end
end
