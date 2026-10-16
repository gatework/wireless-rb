# frozen_string_literal: true

require_relative "../command_output"
require_relative "../configuration"
require "ctx_parser/configuration_parser"

module Wireless
  module H3c
    module Parsers
      # 用缩进保留型号和 Radio 归属；相关命令不受支持时降低完整性。
      class DisplayCurrentConfiguration < CtxParser::ConfigurationParser
        include CommandOutput

        private

        # 声明当前命令解析器所需的换行归一化方式。
        def output_newlines = :preserve

        # 仅构建一次来源块，再将解释结果关联到行状态。
        def parse_text(text, complete:)
          @configuration = H3c::Configuration.new
          @issues = []
          read_configuration(text, comments: nil, boundaries: /\A(?:#|return)\z/)
          recognized = cursor.lines.any? { |line| line.text == "return" }
          blocks.each { |block| recognized = parse_block(block) || recognized }
          @issues << { code: :missing_completeness_evidence } unless complete
          @issues << { code: :unrecognized_configuration } unless recognized
          CtxParser::Result.new(status: @issues.empty? ? :complete : recognized ? :partial : :failed,
            records: recognized ? [ @configuration.data ] : [], issues: @issues)
        end

        # 未知块独立拥有其后代，不能将其放入外层作用域解释。
        def parse_block(block, owner = nil)
          analyze(block) { parse_setting(block, owner) }
        rescue ArgumentError, IPAddr::InvalidAddressError
          @issues << { code: :invalid_configuration_line, line: block.line }
          block.children.each { |child| unrecognized_block(child) }
          false
        end

        # 在所属父级配置作用域内解释一项支持的设置。
        def parse_setting(block, owner)
          line = block.text
          selected = owner ? nested_scope(line, owner) : root_scope(line)
          if selected
            scope(block, selected.path) do
              block.children.each { |child| parse_block(child, selected) }
              selected.finish
            end
            true
          elsif !owner && (match = /\Asysname (\S+)\z/.match(line))
            @configuration.data[:global_settings][:hostname] = match[1]
            capture(block, match[1], [ :global_settings, :hostname ])
            true
          elsif owner
            apply_block(block, owner)
          elsif /\A(?:undo )?(?:wlan|dot1x|mac-authentication)\b/i.match?(line)
            apply_block(block, @configuration.global)
            true
          else
            ignore(block)
            false
          end
        end

        # 返回由顶层无线配置语句选定的型号作用域。
        def root_scope(line)
          if (match = /\Awlan (ap-group|service-template|ap) (\S+)(?: (.+))?\z/i.match(line))
            kind = { "ap-group" => :ap_groups, "service-template" => :service_templates, "ap" => :access_points }.fetch(match[1].downcase)
            name, suffix = match[2], match[3]
            raise ArgumentError, "Invalid service template" if kind == :service_templates && suffix
            raise ArgumentError, "Missing AP model" if kind == :access_points && !suffix&.start_with?("model ")
            @configuration.entity(kind, name, model: suffix&.delete_prefix("model "), type: suffix&.delete_prefix("type "))
          elsif (match = /\Awlan (global-configuration|virtual-ap-group(?: \S+)?|ap-license-group|vip-client-group)\z/i.match(line))
            key = match[1].tr("-", "_").split.first.to_sym
            @configuration.global(key, identity: line.split[2])
          end
        end

        # 仅选择所属配置模型允许的作用域。
        def nested_scope(line, owner)
          case line
          when /\Aap-model (.+)\z/ then owner.model(Regexp.last_match(1))
          when /\Aradio (\d+|2\.4g|5g|6g)\z/i then owner.radio(Regexp.last_match(1))
          when /\A(?:gigabitethernet|smartrate-ethernet|ethernet|ten-gigabitethernet) \d+\z/i
            owner.ethernet(line)
          end
        end

        # 标记已识别叶子语句，不将其嵌套未知语法提升到父对象。
        def apply_block(block, owner)
          unless apply(owner, block.text, @configuration.data)
            unrecognized_block(block)
            return false
          end

          if owner.kind == :global
            if /\A(?:undo )?wlan (?:client-security )?static-(black|white)list\b/.match?(block.text)
              key = block.text.include?("static-blacklist") ? :blacklist : :whitelist
              entries = @configuration.data[key]
              capture(block, entries.last, [ key, entries.size - 1 ])
            else
              capture(block, owner.record, owner.path)
            end
          end
          true
        end

        # 逐来源行记录不支持语法，并保留完整来源块。
        def unrecognized_block(block)
          cursor.mark(block.index, state: :unsupported)
          @issues << { code: :unrecognized_wireless_configuration, line: block.line }
          block.children.each { |child| unrecognized_block(child) }
        end

        # 报告未在预期作用域消费的相关子语句。
        def unparsed_child(block) = unrecognized_block(block)

        # 将已识别的无线设置应用到当前作用域记录。
        def apply(scope, line, config)
          owner, kind, record = scope.record, scope.kind, scope.settings
          words = line.split
          enabled = !line.start_with?("undo ")
          case line
          when /\A(?:undo )?region-code-lock enable\z/
            return false unless kind == :global_configuration
            record[:region_code_lock] = enabled
          when /\Anas-id (\S+)\z/
            return false unless kind == :global_configuration
            record[:nas_id] = Regexp.last_match(1)
          when /\A(?:undo )?rrop anti-bmc network (ipv4-and-ipv6-simple) enable\z/
            return false unless kind == :ap_groups
            (record[:rrop_anti_bmc] ||= {})[:network] = { mode: Regexp.last_match(1), enabled: enabled }
          when /\Arrop anti-bmc default-action (deny|permit)\z/
            return false unless kind == :ap_groups
            (record[:rrop_anti_bmc] ||= {})[:default_action] = Regexp.last_match(1)
          when /\Aserial-id (\S+)\z/
            return false unless %i[access_points ap_groups].include?(kind)
            kind == :ap_groups ? owner[:serial_ids] << words.last : record[:serial_id] = words.last
          when /\Aap (\S+)\z/
            return false unless kind == :ap_groups
            owner[:ap_names] << words.last
          when /\Avlan (\d+)\z/
            vlan = Fields.integer(words.last, max: 4094)
            kind == :ap_groups ? owner[:vlan_ids] << vlan : owner[:vlan_id] = vlan
          when /\Assid (.+)\z/
            return false unless kind == :service_templates
            owner[:ssid] = Regexp.last_match(1)
          when /\A(?:undo )?service-template enable\z/
            return false unless kind == :service_templates
            owner[:enabled] = enabled
          when /\Aservice-template (\S+)(?: vlan (\d+))?\z/
            return false unless kind == :radio
            name, vlan = Regexp.last_match.captures
            binding = { name: name, vlan_id: Fields.integer(vlan, max: 4094) }
            previous = record[:service_templates].find { |entry| entry[:name] == name }
            raise ArgumentError, "Conflicting template binding" if previous && previous != binding
            record[:service_templates] |= [ binding ]
          when /\Apreshared-key\s+.+\z/i
            record[:has_preshared_key] = true
          when /\Aakm mode (.+)\z/
            record[:akm_modes] = Regexp.last_match(1).downcase.gsub("802.1x", "dot1x").split
          when /\A(cipher-suite|security-ie) (.+)\z/
            key = words.first == "cipher-suite" ? :cipher_suites : :security_ies
            record[key] = words.drop(1).map(&:downcase)
          when /\Aclient-security authentication-mode (.+)\z/
            record[:client_security_authentication_mode] = Regexp.last_match(1).downcase
          when /\Aclient-security (ignore-authentication|ignore-authorization)\z/
            record[words.last.tr("-", "_").to_sym] = true
          when /\A(dot1x|mac-authentication) domain (\S+)\z/
            record["#{words.first.tr('-', '_')}_domain".to_sym] = words.last
          when /\Aportal (enable method|domain|bas-ip|apply web-server|apply mac-trigger-server) (\S+)\z/
            key, value = Regexp.last_match.captures
            # 仅保留 Portal 是否存在；URL 与凭据不属于无线清单契约。
            (record[:portal] ||= {})[key.tr(" -", "__").to_sym] = value.include?("://") ? true : value
          when /\A(?:undo )?(dot1x|mac-authentication)\z/
            record["#{Regexp.last_match(1).tr('-', '_')}_enabled".to_sym] = enabled
          when /\Adot1x authentication-method (chap|eap|pap)\z/
            record[:dot1x_authentication_method] = Regexp.last_match(1)
          when /\Amac-authentication user-name-format fixed(?: account \S+)?(?: password (simple|cipher) \S+)?\z/
            # 固定账号的明文和密文均不进入普通事实或捕获快照。
            storage = Regexp.last_match(1)
            record[:mac_authentication_user_name_format] = "fixed"
            record[:mac_authentication_has_password] = !storage.nil?
          when /\Amac-authentication user-name-format (mac-address(?: (?:with-hyphen|without-hyphen))?(?: (?:lowercase|uppercase))?)\z/
            record[:mac_authentication_user_name_format] = Regexp.last_match(1)
            record.delete(:mac_authentication_has_password)
          when /\Adot1x timer (supp-timeout|tx-period) (\d+)\z/
            (record[:dot1x_timers] ||= {})[words[2].tr("-", "_").to_sym] = Fields.integer(words.last)
          when /\Awlan (?:client-security )?static-(black|white)list mac-address (\S+)(?: (.+))?\z/
            kind, mac, reason = Regexp.last_match.captures
            config[kind == "black" ? :blacklist : :whitelist] << { mac_address: Fields.mac(mac), reason: reason }
          when /\A(?:undo )?(?:wlan )?(auto-ap|auto-persistent|band-navigation|client inspect|radio-load-balance band-navigation) enable\z/
            record[Regexp.last_match(1).tr(" -", "__").to_sym] = enabled
          when /\A(?:undo )?(beacon ssid-hide|bss transition-management enable)\z/
            record[line.include?("ssid-hide") ? :ssid_hidden : :btm_enabled] = enabled
          when /\A(client keep-alive|client-rate-limit|firmware-upgrade|radio) (enable|disable)\z/
            key = { "client keep-alive" => :client_keep_alive, "client-rate-limit" => :client_rate_limit_enabled,
              "firmware-upgrade" => :firmware_upgrade, "radio" => :enabled }.fetch(Regexp.last_match(1))
            record[key] = words.last == "enable"
          when /\A(client keep-alive interval|client max-count|client cache aging-time|bss transition-management disassociation forced timer|statistics-interval|priority|dot1x retry|wlan tcp mss) (\d+)\z/
            key = { "client keep-alive interval" => :client_keep_alive_interval, "client max-count" => :client_max_count,
              "client cache aging-time" => :client_cache_aging_time, "bss transition-management disassociation forced timer" => :btm_disassociation_timer,
              "statistics-interval" => :statistics_interval, "priority" => :priority, "dot1x retry" => :dot1x_retry, "wlan tcp mss" => :tcp_mss }.fetch(Regexp.last_match(1))
            record[key] = Fields.integer(words.last)
          when /\A(?:description|map-configuration) (.+)\z/
            record[words.first.tr("-", "_").to_sym] = words.drop(1).join(" ")
          when /\Abackup-ac ip (\S+)\z/ then record[:backup_ac_ip] = Fields.ip(words.last)
          when /\Achannel band-width (.+)\z/ then record[:channel_bandwidth] = Regexp.last_match(1)
          when /\Achannel auto unlock\z/ then record.merge!(channel: "auto", channel_number: nil, channel_unlocked: true)
          when /\Achannel (.+)\z/
            record[:channel] = Regexp.last_match(1)
            record[:channel_number] = Fields.channel(record[:channel])
          when /\Amax-power (\d+(?:\.\d+)?)\z/ then record[:max_power] = Fields.number(words.last)
          when /\Aclient-rate-limit (inbound|outbound) mode (\S+) cir (\d+)\z/
            (record[:client_rate_limit] ||= {})[words[1].to_sym] = { mode: words[3], cir_bps: Fields.integer(words.last) * 1000 }
          when /\Arate (mandatory|supported|disabled|multicast) (.+)\z/
            (record[:rates] ||= {})[words[1].to_sym] = words[1] == "multicast" ? words.drop(2).join(" ") : words.drop(2).map { |word| Fields.number(word) }
          when /\Aoption client (reject|reconnect) enable rssi (-?\d+(?:\.\d+)?)\z/
            (record[:client_options] ||= {})[words[2].to_sym] = Fields.number(words.last)
          when /\Asacp anti-sticky enable(?: rssi (-?\d+(?:\.\d+)?))? interval (\d+)\z/
            signal, interval = Regexp.last_match.captures
            record[:anti_sticky] = { enabled: true, rssi: Fields.number(signal), interval: Fields.integer(interval) }
          when /\Apacket-filter name (\S+) (inbound|outbound)\z/
            (record[:packet_filters] ||= {})[words.last.to_sym] = words[2]
          when /\A(?:client forwarding-location|wlan image-load filepath|wlan fast-forwarding mode|led-mode) (\S+)\z/
            key = { "client" => :forwarding_location, "wlan image-load" => :image_load_filepath,
              "wlan fast-forwarding" => :fast_forwarding_mode, "led-mode" => :led_mode }
            record[key.fetch(words.first == "wlan" ? words.take(2).join(" ") : words.first)] = words.last
          when /\A(local|member) ip (\S+)\z/
            words.first == "local" ? record[:local_ip] = Fields.ip(words.last) : (record[:member_ips] ||= []) << Fields.ip(words.last)
          when /\Aclient-mac (\S+)\z/ then (record[:mac_addresses] ||= []) << Fields.mac(words.last)
          when "wlan tunnel-preempt enable" then record[:tunnel_preempt] = true
          when "broadcast-probe reply disable" then record[:broadcast_probe_reply] = false
          when "radar-detect disable" then record[:radar_detect_disabled] = true
          when "calibrate-channel self-decisive enable all" then record[:calibrate_channel] = true
          when "calibrate-power self-decisive enable all" then record[:calibrate_power] = true
          when "ap-license-synchronization enable" then record[:license_synchronization] = true
          else return false
          end
          true
        end
      end
    end
  end
end
