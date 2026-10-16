# frozen_string_literal: true

require_relative "../session_parser"

module Wireless
  module H3c
    module Parsers
      # 同时接受以 BSSID 或 AP 名称开头的 BSS 块。
      class DisplayWlanBssAllVerbose < SessionParser
        MAPPING = COMMON_FIELDS.merge("service template" => :profile, "service template name" => :profile,
          "state" => :operational_status, "client count" => :client_count, "number of clients" => :client_count,
          "online clients" => :client_count).freeze
        SECURITY = [ "security mode", "akm mode", "cipher suite", "bss id", "user authentication mode", "tx bssid", "ft status", "btm status", "mlo status" ].freeze
        IDENTITY = [ :bssid ].freeze
        COUNT = "BSSs?".freeze

        private

        # 返回当前命令格式中用于开始新记录的字段。
        def start_label(fields)
          first = fields.find { |label,| label == "bssid" || label == "ap name" }
          "ap name" if first&.first == "ap name"
        end

        # 要求具备关联当前记录所需的稳定身份字段。
        def valid_identity?(record)
          super && record[:ap_name] && !record[:ap_name].strip.empty? && !record[:radio_id].nil?
        end

        # 保留 BSS 安全字段，其余字段委派给共享会话解析器。
        def assign_session_field(record, label, raw, issues, line)
          if SECURITY.include?(label)
            (record[:security] ||= {})[label.tr(" -", "__").to_sym] = raw
          else
            super
          end
        end
      end
    end
  end
end
