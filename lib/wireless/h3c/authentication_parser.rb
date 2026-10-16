# frozen_string_literal: true

require_relative "session_parser"

module Wireless
  module H3c
    # 认证命令共享字段语法及复合会话身份。
    class AuthenticationParser < SessionParser
      MAPPING = COMMON_FIELDS.except("vlan id", "service vlan id").merge(
        "mac address" => :mac_address, "user mac address" => :mac_address, "username" => :username, "user name" => :username,
        "access interface" => :interface, "interface" => :interface, "ip address" => :ip_address,
        "ipv4 address" => :ip_address, "ipv6 address" => :ipv6_address, "authentication domain" => :domain, "domain" => :domain,
        "authentication method" => :protocol, "authentication protocol" => :protocol, "auth protocol" => :protocol,
        "access protocol" => :protocol, "protocol" => :protocol, "authentication state" => :state, "state" => :state, "status" => :state,
        "initial vlan" => :initial_vlan_id, "initial vlan id" => :initial_vlan_id, "authorization vlan" => :authorized_vlan_id,
        "authorization vlan id" => :authorized_vlan_id, "authorized vlan" => :authorized_vlan_id,
        "authorized vlan id" => :authorized_vlan_id, "online time" => :online_seconds, "online duration" => :online_seconds).freeze
      DETAILS = [ "anonymous username", "authorization acl number", "authorization dynamic acl name", "authorization user profile",
        "authorization car", "authorization url", "authorization ipv6 url", "authorization microsegment id", "termination action",
        "session timeout last from", "session timeout period", "online from" ].freeze
      IDENTITY = [ :mac_address, :interface, :bssid ].freeze
      COUNT = "(?:connections|users|online users)".freeze
    end
  end
end
