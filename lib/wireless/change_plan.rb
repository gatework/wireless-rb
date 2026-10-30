# frozen_string_literal: true

require "ctx_parser/immutable"
require_relative "configuration_index"

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

      def to_h = @value

      def eligible?(config) = ChangePlan.eligible?(config, @value)

      # 只允许目标模板的两个协议集合变化，其余配置必须与执行前一致。
      def satisfied?(after, before:)
        return false unless eligible?(before)
        templates = before.fetch("service_templates").map do |template|
          next template unless template["name"] == @value["name"]
          settings = template.fetch("configuration").merge(
            "cipher_suites" => @value["cipher_suites"] - [ "tkip" ],
            "security_ies" => @value["security_ies"] - [ "wpa" ])
          template.merge("configuration" => settings)
        end
        after == before.merge("service_templates" => templates)
      end
      def inspect = "#<#{self.class.name}>"
    end

    def self.build(value) = Change.new(value)

    def self.candidate(value, config:)
      change = build(value)
      change if change.eligible?(config)
    rescue ArgumentError
      nil
    end

    # 安全参数变更前停用模板，结束后只恢复原启用状态。
    def self.render(change)
      fields = %w[kind name enabled cipher_suites security_ies]
      unless change.is_a?(Hash) && change.keys.sort == fields.sort
        raise ArgumentError, "Unsupported change fields"
      end
      name = change["name"]
      unless change["kind"] == "wireless_security" && name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]{1,63}\z/) && [ true, false ].include?(change["enabled"])
        raise ArgumentError, "不支持的模板增量"
      end
      ciphers, ies = change.values_at("cipher_suites", "security_ies")
      unless ciphers.is_a?(Array) && ies.is_a?(Array) && ciphers.all?(String) && ies.all?(String) && ciphers.uniq == ciphers && ies.uniq == ies && ciphers.include?("ccmp") && ies.include?("rsn") && (ciphers.include?("tkip") || ies.include?("wpa"))
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
      template = ConfigurationIndex.coerce(config).template(change["name"])
      return false unless template
      template["enabled"] == change["enabled"] && %w[cipher_suites security_ies].all? { |key| template.dig("configuration", key) == change[key] }
    rescue ArgumentError
      false
    end
  end
end
