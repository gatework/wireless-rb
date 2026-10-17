# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "parsers/display_wlan_ap_all_verbose"
require_relative "parsers/display_wlan_bss_all_verbose"
require_relative "parsers/display_wlan_client_verbose"
require_relative "parsers/display_current_configuration"
require_relative "parsers/display_dot1x_connection"
require_relative "parsers/display_mac_authentication_connection"
require_relative "parsers/display_wlan_client_security_block_mac"
require_relative "parsers/display_lldp_neighbor_information_verbose"
require_relative "parsers/display_wlan_statistics_client_ip_conflict"
require_relative "parsers/display_wlan_ap_model_all"

module Wireless
  module H3c
    # 声明 H3C 控制器及 AP 策略，共享回显仅解析一次后再投影维度。
    class Profile < CtxParser::Profile
      DECLARATIONS = CtxParser::Commands.new([
        { dimensions: [ :client_ip_conflicts ], command: "display wlan statistics client-ip-conflict", parser: Parsers::DisplayWlanStatisticsClientIpConflict },
        { dimensions: [ :ap_models ], command: "display wlan ap-model all", parser: Parsers::DisplayWlanApModelAll },
        { dimensions: %i[access_points radios], command: "display wlan ap all verbose", parser: Parsers::DisplayWlanApAllVerbose },
        { dimensions: [ :bsses ], command: "display wlan bss all verbose", parser: Parsers::DisplayWlanBssAllVerbose },
        { dimensions: [ :clients ], command: "display wlan client verbose", parser: Parsers::DisplayWlanClientVerbose },
        { dimensions: %i[configuration ap_groups service_templates], command: "display current-configuration", parser: Parsers::DisplayCurrentConfiguration },
        { dimensions: [ :dot1x_connections ], command: "display dot1x connection", parser: Parsers::DisplayDot1xConnection },
        { dimensions: [ :mab_connections ], command: "display mac-authentication connection", parser: Parsers::DisplayMacAuthenticationConnection },
        { dimensions: [ :blocked_clients ], command: "display wlan client-security block-mac", parser: Parsers::DisplayWlanClientSecurityBlockMac },
        { dimensions: [ :lldp ], command: "display lldp neighbor-information verbose", parser: Parsers::DisplayLldpNeighborInformationVerbose }
      ])
      COMMANDS = DECLARATIONS.by_dimension
      PARSERS = DECLARATIONS.parsers

      # 本平台在当前控制器会话禁用分页。
      def preparation_command = "screen-length disable"

      private

      # 从共享命令结果中提取请求维度。
      def project(name, result)
        return super unless %i[ap_groups service_templates].include?(name)

        records = result.records.first&.fetch(name) || []
        result.with(records: records)
      end
    end
  end
end
