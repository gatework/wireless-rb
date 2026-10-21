# frozen_string_literal: true

require "ctx_runner/fingerprint"
require "json"

module Wireless
  # 只支持已知 H3C 模板加固增量，不接收任意命令文本。
  module ChangePlan
    # 固定领域参数和命令，公共执行器只调用明确的前后置条件。
    class Change
      attr_reader :commands, :rollback

      def initialize(value)
        @value = CtxParser::Immutable.copy(value)
        @commands, @rollback = CtxParser::Immutable.copy(ChangePlan.render(@value))
        freeze
      end

      def eligible?(config) = ChangePlan.eligible?(config, @value)
      def satisfied?(after, before:) = ChangePlan.satisfied?(after, @value)
      def inspect = "#<#{self.class.name}>"
    end

    def self.build(value) = Change.new(value)

    # 配置映射顺序不影响指纹，列表顺序保持语义。
    def self.fingerprint(value) = CtxRunner::Fingerprint.call(value)

    # 兼容既有领域入口，配置身份协议仅由 Runner 实现。
    def self.canonical(value) = CtxRunner::Fingerprint.canonical(value)

    # 安全参数变更前停用模板，结束后只恢复原启用状态。
    def self.render(change)
      name = change["name"]
      unless change["kind"] == "wireless_security" && name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]{1,63}\z/) && [ true, false ].include?(change["enabled"])
        raise ArgumentError, "不支持的模板增量"
      end
      ciphers, ies = change.values_at("cipher_suites", "security_ies")
      unless ciphers.is_a?(Array) && ies.is_a?(Array) && ciphers.include?("ccmp") && ies.include?("rsn") && (ciphers.include?("tkip") || ies.include?("wpa"))
        raise ArgumentError, "缺少安全替代协议"
      end
      remove, restore = [], []
      if ies.include?("wpa")
        remove << " undo security-ie wpa"
        restore << " security-ie wpa"
      end
      if ciphers.include?("tkip")
        remove << " undo cipher-suite tkip"
        restore.unshift(" cipher-suite tkip")
      end
      [ remove, restore ].map { |commands| [ "system-view", "wlan service-template #{name}", " undo service-template enable", *commands, *(change["enabled"] ? [ " service-template enable" ] : []), "quit", "return" ] }
    end

    # 只修改与源模板状态完全匹配的明确事实。
    def self.eligible?(config, change)
      render(change)
      template = config.fetch("service_templates", []).find { |entry| entry["name"] == change["name"] }
      template && template["enabled"] == change["enabled"] && %w[cipher_suites security_ies].all? { |key| template.dig("configuration", key) == change[key] }
    rescue ArgumentError
      false
    end

    # 验收检查精确协议集合及原启停状态，避免仅凭 CLI 成功确认完成。
    def self.satisfied?(config, change)
      template = config.fetch("service_templates", []).find { |entry| entry["name"] == change["name"] }
      template && template["enabled"] == change["enabled"] && template.dig("configuration", "cipher_suites") == change["cipher_suites"] - [ "tkip" ] && template.dig("configuration", "security_ies") == change["security_ies"] - [ "wpa" ]
    end
  end
end
