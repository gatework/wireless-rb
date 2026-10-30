# frozen_string_literal: true

require_relative "parser"

module Wireless
  module H3c
    # 按字段标签划分 H3C 详细记录，并共享字段转换与诊断。
    class RecordParser < Parser
      COMMON_FIELDS = { "ap name" => :ap_name, "ap id" => :ap_id, "radio id" => :radio_id,
        "ssid" => :ssid, "bssid" => :bssid, "vlan id" => :vlan, "service vlan id" => :service_vlan }.freeze
      DETAILS = [].freeze

      private

      # 各命令声明记录身份与字段映射，嵌套记录可覆盖此入口。
      def parse_text(text, complete:)
        issues, records = [], []
        fields = read_fields(text, issues)
        start_label = record_start_label(fields)
        current = nil
        fields.each do |label, raw, line|
          if start_label ? label == start_label : self.class::MAPPING[label] == self.class::IDENTITY.first
            current = {}
            records << current
          end
          unless current
            issues << { code: :missing_identity, line: line }
            next
          end
          assign_record_field(current, label, raw, issues, line)
        end
        records.reject! do |record|
          invalid = !valid_identity?(record)
          issues << { code: :invalid_identity } if invalid
          invalid
        end
        Fields.result(records, issues: issues, complete: complete, total: reported_record_total(text, self.class::COUNT, issues), identity: self.class::IDENTITY)
      end

      # 返回字段标签、原始值与来源行号，保留明确允许的续行。
      def read_fields(text, issues)
        text.lines("\n").each_with_index.each_with_object([]) do |(line, index), fields|
          row = line.strip
          next if row.empty? || /\A[-=]+\z/.match?(row)
          if (match = /\A([^:]+?)\s*:\s*(.*)\z/.match(row))
            label = match[1].downcase.gsub(/\s+/, " ")
            next if /\A(?:total|number of aps|connected|remaining|maximum|current number|(?:local|server|sync) ap licenses|(?:current|max|bound) bss number)\b/.match?(label)
            fields << [ label, Fields.value(match[2]), index + 1, line[/\A\s*/].size ]
          elsif (match = /\A:\s*(\S.*)\z/.match(row)) && fields.last&.first == "poe status"
            fields.last[1] = [ fields.last[1], match[1] ].compact.join("\n")
          elsif /\A(?:NSS\d+\s+[\d, ]+|TID \d+\s+(?:In|Out|Both)|[\d., ]+(?:Mbps)?)\z/.match?(row)
            next
          else
            issues << { code: :unrecognized_line, line: index + 1 }
          end
        end
      end

      # 更新当前记录前，先应用字段专用转换。
      def assign_field(record, mapping, label, raw, issues, line, details:)
        if record && (field = mapping[label])
          with_field_validation(issues, line) do
            # 优先使用运行带宽；80+80MHz 等歧义值保持原义，不截断为单个数值。
            if field == :channel_width_mhz
              label = "channel bandwidth" if label == "channel band-width"
              assign_value(record[:details] ||= {}, label.tr(" ", "_").to_sym, raw, issues, line)
              return if label == "channel bandwidth" && @field_assignments.fetch(record[:details]).key?(:operating_bandwidth)
            end
            assign_value(record, field, convert_field(field, raw, label: label), issues, line, identity: field == :channel_width_mhz ? label : field)
          end
        elsif details
          value = label.end_with?("url") ? !raw.nil? && !raw.strip.empty? : raw
          assign_value(details[:details] ||= {}, label.tr(" -", "__").to_sym, value, issues, line)
        else
          issues << { code: :unrecognized_field, line: line }
        end
      end

      # 按声明的归一化规则转换已知字段。
      def convert_field(field, raw, label:)
        case field
        when :mac_address, :client_mac, :bssid then Fields.mac_address(raw)
        when :management_ip, :client_ip, :client_ipv6, :ip_address, :ipv6_address
          address = Fields.ip_address(raw)
          if address && ((label == "ipv4 address" && address.include?(":")) || (label == "ipv6 address" && !address.include?(":")))
            raise ArgumentError, "Invalid wireless address family"
          end
          address
        when :ap_id, :radio_id then Fields.integer(raw)&.to_s
        when :client_count, :online_seconds, :uptime_seconds
          %i[online_seconds uptime_seconds].include?(field) ? Fields.duration_seconds(raw) : Fields.integer(raw)
        when :vlan, :service_vlan, :initial_vlan_id, :authorized_vlan_id
          Fields.vlan_id(raw)
        when :channel then Fields.channel(raw)
        when :channel_width_mhz then Fields.channel_width_mhz(raw)
        when :band then Fields.frequency_band(raw)
        when :noise_dbm then Fields.number(raw, unit: "dBm")&.then { |number| number if number.negative? }
        when :utilization_percent
          number = Fields.number(raw, unit: "%")
          raise ArgumentError, "Invalid wireless utilization_percent" if number && !(0..100).cover?(number)
          number&.round
        else raw
        end
      end

      # 解析非负计数，同时保留未知值。
      def reported_record_total(text, noun, issues)
        reported_total(text, noun: noun, issues: issues)
      end

      # 隔离单个格式错误字段，同时保留无关记录数据。
      def with_field_validation(issues, line)
        yield
      rescue ArgumentError, IPAddr::InvalidAddressError
        issues << { code: :invalid_field, line: line }
      end

      # 默认以身份字段开始新记录，命令可声明其他起始标签。
      def record_start_label(fields)
        nil
      end

      # 要求具备关联当前记录所需的稳定身份字段。
      def valid_identity?(record)
        value = record[self.class::IDENTITY.first]
        value && !value.strip.empty?
      end

      # 将命令字段归一化到当前记录，并保留显式允许的详情。
      def assign_record_field(record, label, raw, issues, line)
        details = self.class::DETAILS.include?(label) ? record : nil
        assign_field(record, self.class::MAPPING, label, raw, issues, line, details: details)
      end
    end
  end
end
