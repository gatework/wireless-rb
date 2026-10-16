# frozen_string_literal: true

require_relative "verbose_parser"

module Wireless
  module H3c
    # 复用详细会话边界，各命令独立声明其字段结构。
    class SessionParser < VerboseParser
      COMMON_FIELDS = { "ap name" => :ap_name, "ap id" => :ap_id, "radio id" => :radio_id,
        "ssid" => :ssid, "bssid" => :bssid, "vlan id" => :vlan, "service vlan id" => :vlan }.freeze
      DETAILS = [].freeze

      private

      # 解释当前命令记录，保留不完整行诊断。
      def parse_text(text, complete:)
        issues, records = [], []
        fields = tokens(text, issues)
        start = start_label(fields)
        current = nil
        fields.each do |label, raw, line|
          if start ? label == start : self.class::MAPPING[label] == self.class::IDENTITY.first
            current = {}
            records << current
          end
          unless current
            issues << { code: :missing_identity, line: line }
            next
          end
          assign_session_field(current, label, raw, issues, line)
        end
        records.reject! do |record|
          invalid = !valid_identity?(record)
          issues << { code: :invalid_identity } if invalid
          invalid
        end
        Fields.result(records, issues: issues, complete: complete, total: count(text, self.class::COUNT), identity: self.class::IDENTITY)
      end

      # 返回当前命令格式中用于开始新记录的字段。
      def start_label(fields)
        nil
      end

      # 要求具备关联当前记录所需的稳定身份字段。
      def valid_identity?(record)
        value = record[self.class::IDENTITY.first]
        value && !value.strip.empty?
      end

      # 将单个认证会话字段归一化到目标记录。
      def assign_session_field(record, label, raw, issues, line)
        details = self.class::DETAILS.include?(label) ? record : nil
        assign_field(record, self.class::MAPPING, label, raw, issues, line, details: details)
      end
    end
  end
end
