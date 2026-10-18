# frozen_string_literal: true

require "time"

module Wireless
  # 证据新鲜度独立于保留的资产清单及已观察设备故障进行报告。
  class Coverage
    # 绑定观测、投影结果及请求的新鲜度时间窗。
    def initialize(observations:, projection:, dimensions:, now:, stale_after:)
      unless now.is_a?(Time) && stale_after.is_a?(Numeric) && stale_after.real? && stale_after.finite? && stale_after >= 0
        raise ArgumentError, "Coverage requires a clock time and a finite nonnegative freshness window"
      end

      @observation_history, @projection, @dimensions = observations, projection || {}, dimensions
      @now, @stale_after_seconds = now, stale_after
    end

    # 历史资产清单不声明 CLI 完整性，保持既有纯 Netdisco 视图兼容。
    def to_h
      return { "state" => "untracked", "source" => "inventory", "dimensions" => {} } unless @observation_history

      dimensions = @dimensions.to_h { |name| [ name.to_s, dimension_coverage(name.to_s) ] }
      states = dimensions.values.map { |entry| entry.fetch("state") }
      state = if states.empty? || states.include?("unknown")
        "unknown"
      elsif states.all?("complete")
        "complete"
      else
        "stale"
      end
      { "state" => state, "source" => "cli", "dimensions" => dimensions }
    end

    private

    # 新记录不能刷新旧命令或失败命令的时效；投影受阻不算完整覆盖。
    def dimension_coverage(name)
      stored = @observation_history.fetch(name, {})
      latest = stored.fetch("latest", {})
      projection = @projection.fetch(name, {})
      at = parse_timestamp(latest["completed_at"] || latest["observed_at"])
      projected_at = parse_timestamp(projection["observed_at"])
      last_complete = latest["status"] == "complete" ? latest : stored.fetch("last_complete", {})
      state, reason = if latest["status"] != "complete"
        [ "unknown", latest.empty? ? "not_requested" : "collection_#{latest['status']}" ]
      elsif !at || at > @now
        [ "unknown", "observation_time_unknown" ]
      elsif @now - at > @stale_after_seconds
        [ "stale", "evidence_stale" ]
      elsif @projection.key?(name) && projected_at != at
        [ "unknown", "projection_time_unconfirmed" ]
      elsif @projection.key?(name) && projection["status"] != "complete"
        [ "unknown", "projection_incomplete" ]
      else
        [ "complete", nil ]
      end
      { "state" => state, "status" => latest["status"] || "not_requested", "reason" => reason,
        "observed_at" => at&.iso8601(6),
        "last_complete_at" => parse_timestamp(last_complete["completed_at"] || last_complete["observed_at"])&.iso8601(6),
        "projection_status" => projection["status"], "projection_observed_at" => projected_at&.iso8601(6) }.compact
    end

    # 历史时间戳格式错误时视为证据不可用，不能当作新鲜观测。
    def parse_timestamp(value)
      Time.iso8601(value) if value.is_a?(String)
    rescue ArgumentError
      nil
    end
  end
end
