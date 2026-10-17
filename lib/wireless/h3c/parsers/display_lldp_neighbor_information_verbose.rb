# frozen_string_literal: true

require_relative "../parser"

module Wireless
  module H3c
    module Parsers
      # AP LLDP 端点与控制器资产区分处理，并要求明确的零邻居证据。
      class DisplayLldpNeighborInformationVerbose < Parser
        DETAILS = [ "system description", "port description", "port vlan id", "vlan id", "maximum frame size",
          "chassis type", "port type", "port id type", "management address type", "update time", "time to live",
          "system capabilities supported", "system capabilities enabled", "management address interface type",
          "management address interface id", "management address oid", "link aggregation supported", "link aggregation enabled",
          "aggregation port id", "auto-negotiation supported", "auto-negotiation enabled", "opermau", "power port class",
          "pse power supported", "pse power enabled", "pse pairs control ability", "power pairs", "port power classification",
          "power type", "power source", "power priority", "pd requested power value", "pse allocated power value" ].freeze

        private

        # 解释当前命令记录，保留不完整行诊断。
        def parse_text(text, complete:)
          records, issues = [], []
          current = nil
          local = nil
          description_indent = nil
          description = description_line = nil
          store_description = lambda do
            if description
              assign_value(current[:details] ||= {}, :system_description, description, issues, description_line)
              description = description_indent = nil
            end
          end
          continuation_lines = {}
          flush = lambda do
            if current && current.values_at(:local_interface, :remote_chassis_id, :remote_interface).all? { |value| value && !value.strip.empty? }
              if /mac address/i.match?(current.dig(:details, :chassis_type).to_s)
                begin
                  current[:remote_chassis_id] = Fields.mac_address(current[:remote_chassis_id])
                rescue ArgumentError
                  issues << { code: :invalid_chassis_id }
                  current = nil
                  next
                end
              end
              records << current
            elsif current
              issues << { code: :incomplete_neighbor }
            end
            current = nil
          end
          text.lines.each_with_index do |line, index|
            row = line.strip
            next if row.empty? || /\A[-=]+\z/.match?(row)
            if description_indent && line[/\A\s*/].size > description_indent
              description << "\n" << row
              continuation_lines[index + 1] = true
              next
            end
            store_description.call
            if (match = /\ALLDP neighbor-information of port \d+\[(.+?)\]\s*:?\z/i.match(row))
              flush.call
              local = match[1]
            elsif /\ALLDP neighbor index\s*:/i.match?(row)
              flush.call
              current = { local_interface: local }
            elsif /\A(?:LLDP agent\s+[^:]+:|No (?:LLDP )?neighbors|(?:Total|Number of neighbors).*:\s*\d+)\s*\z/i.match?(row)
              next
            elsif (match = /\A([^:]+):\s*(.*?)\z/.match(row))
              label, raw = match.captures
              label = label.strip.downcase
              current ||= { local_interface: local }
              case label
              when "chassis id" then assign_value(current, :remote_chassis_id, raw, issues, index + 1)
              when "port id" then assign_value(current, :remote_interface, raw, issues, index + 1)
              when "system name" then assign_value(current, :remote_name, Fields.value(raw), issues, index + 1)
              when "management address"
                begin
                  assign_value(current, :management_address, Fields.ip_address(Fields.value(raw)), issues, index + 1)
                rescue IPAddr::InvalidAddressError, ArgumentError
                  issues << { code: :invalid_management_address, line: index + 1 }
                end
              when "port vlan id(pvid)" then assign_value(current[:details] ||= {}, :port_vlan_id, raw, issues, index + 1)
              when *DETAILS
                if label == "system description"
                  description = raw.dup
                  description_line = index + 1
                  description_indent = line[/\A\s*/].size
                else
                  assign_value(current[:details] ||= {}, label.tr(" ", "_").to_sym, raw, issues, index + 1)
                end
              else issues << { code: :unrecognized_field, line: index + 1 }
              end
            else
              issues << { code: :unrecognized_line, line: index + 1 }
            end
          end
          store_description.call
          flush.call
          total = reported_total(text, noun: "(?:LLDP )?neighbors", issues: issues, continuation_lines: continuation_lines)
          total ||= 0 if /\ANo (?:LLDP )?neighbors\s*$/i.match?(text.strip)
          Fields.result(records, issues: issues, complete: complete, total: total,
            identity: %i[local_interface remote_chassis_id remote_interface])
        end
      end
    end
  end
end
