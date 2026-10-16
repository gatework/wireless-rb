# frozen_string_literal: true

require_relative "parser"

module Wireless
  module H3c
    # 为 H3C 详细命令回显共享词元切分与类型化字段处理。
    class VerboseParser < Parser
      private

      # 切分含引号的命令值，不将其作为 Ruby 代码解释。
      def tokens(text, issues)
        text.lines.each_with_index.each_with_object([]) do |(line, index), fields|
          row = line.strip
          next if row.empty? || /\A[-=]+\z/.match?(row)
          if (match = /\A([^:]+?)\s*:\s*(.*)\z/.match(row))
            label = match[1].downcase.gsub(/\s+/, " ")
            next if /\A(?:total|number of aps|connected|remaining|maximum|current number|(?:local|server|sync) ap licenses|(?:current|max|bound) bss number)\b/.match?(label)
            fields << [ label, Fields.value(match[2]), index + 1 ]
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
          safely(issues, line) do
            # 优先使用运行带宽；80+80MHz 等歧义值保持原义，不截断为单个数值。
            if field == :channel_width
              (record[:details] ||= {})[label.tr(" ", "_").to_sym] = raw
              return if label == "channel bandwidth" && record[:details].key?(:operating_bandwidth)
            end
            record[field] = convert(field, raw)
          end
        elsif details
          (details[:details] ||= {})[label.tr(" -", "__").to_sym] = label.end_with?("url") ? !raw.nil? && !raw.strip.empty? : raw
        else
          issues << { code: :unrecognized_field, line: line }
        end
      end

      # 按声明的归一化规则转换已知字段。
      def convert(field, raw)
        case field
        when :mac_address, :client_mac, :bssid then Fields.mac(raw)
        when :management_ip, :client_ip, :client_ipv6, :ip_address, :ipv6_address then Fields.ip(raw)
        when :ap_id, :radio_id then Fields.integer(raw)&.to_s
        when :client_count, :online_seconds, :uptime_seconds
          %i[online_seconds uptime_seconds].include?(field) ? Fields.duration(raw) : Fields.integer(raw)
        when :vlan, :initial_vlan_id, :authorized_vlan_id then Fields.integer(raw, max: 4094)
        when :channel then Fields.channel(raw)
        when :channel_width then Fields.width(raw)
        when :band then Fields.band(raw)
        when :noise_dbm then Fields.number(raw, unit: "dBm")&.then { |number| number if number.negative? }
        when :utilization
          number = Fields.number(raw, unit: "%")
          raise ArgumentError, "Invalid wireless utilization" if number && !(0..100).cover?(number)
          number&.round
        else raw
        end
      end

      # 解析非负计数，同时保留未知值。
      def count(text, noun)
        /(?:Total(?: number of)?\s+(?:#{noun})|Total|Current BSS number)\s*:\s*(\d+)\s*$/i.match(text)&.[](1)&.to_i
      end

      # 隔离单个格式错误字段，同时保留无关记录数据。
      def safely(issues, line)
        yield
      rescue ArgumentError, IPAddr::InvalidAddressError
        issues << { code: :invalid_field, line: line }
      end
    end
  end
end
