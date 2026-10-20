# frozen_string_literal: true

require "digest"
require "json"

module Wireless
  # 只支持已知 H3C 模板加固增量，不接收任意命令文本。
  module ChangePlan
    # 配置映射顺序不影响指纹，列表顺序保持语义。
    def self.fingerprint(value) = Digest::SHA256.hexdigest(JSON.generate(canonical(value)))

    # 保存 JSON 与实时事实共用字符串键表示。
    def self.canonical(value)
      case value
      when Hash then value.transform_keys(&:to_s).sort.to_h.transform_values { |entry| canonical(entry) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

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
