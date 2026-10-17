# frozen_string_literal: true

require_relative "../command_output"
require_relative "../configuration"
require_relative "../document"
require "ctx_parser/configuration"

module Wireless
  module H3c
    module Parsers
      # 用缩进保留型号和 Radio 归属；相关命令不受支持时降低完整性。
      class DisplayCurrentConfiguration < CtxParser::Configuration
        include CommandOutput

        private

        # 配置由 Document 标记受损行，仍保留无关事实和原始来源。
        def terminal_issue(_text) = nil

        # 声明当前命令解析器所需的换行归一化方式。
        def output_newlines = :preserve

        # 仅构建一次来源块，再将解释结果关联到行状态。
        def parse_text(text, complete:)
          @configuration = H3c::Configuration.new
          @issues = []
          @setting_assignments = {}.compare_by_identity
          read_configuration(text, comments: nil, boundaries: /\A(?:#|return)\z/, document_class: Document)
          @issues.concat(document.issues)
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
            parse_scope(block, selected)
            true
          elsif !owner && (match = /\Asysname (\S+)\z/.match(line))
            settings = @configuration.data[:global_settings]
            assign_setting(settings, :hostname, match[1], block)
            capture(block, settings[:hostname], [ :global_settings, :hostname ]) if settings.key?(:hostname)
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
            if kind == :ap_groups && suffix && !/\Atype \S+\z/i.match?(suffix)
              raise ArgumentError, "Invalid AP group type"
            end
            raise ArgumentError, "Invalid service template" if kind == :service_templates && suffix
            raise ArgumentError, "Missing AP model" if kind == :access_points && !/\Amodel \S+\z/i.match?(suffix.to_s)
            @configuration.entity(kind, name, model: suffix&.sub(/\Amodel /i, ""), type: suffix&.sub(/\Atype /i, ""))
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
          unless apply(owner, block, @configuration.data)
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
          pending = [ block ]
          until pending.empty?
            current = pending.pop
            cursor.mark(current.index, state: :unsupported)
            @issues << { code: :unrecognized_wireless_configuration, line: current.line }
            pending.concat(current.children.reverse)
          end
        end

        # 无关配置可忽略，未知父级内的无线声明不能被当作不存在。
        def ignore(block)
          pending = [ block ]
          until pending.empty?
            current = pending.pop
            if /\A(?:undo )?wlan\b/i.match?(current.text)
              unrecognized_block(current)
            else
              cursor.mark(current.index, state: :ignored)
              pending.concat(current.children.reverse)
            end
          end
          nil
        end

        # 报告未在预期作用域消费的相关子语句。
        def unparsed_child(block) = unrecognized_block(block)

        # 每个声明块独立检查单值；重复进入的顺序配置仍保留各自来源快照。
        def parse_scope(block, owner)
          previous_assignments = @setting_assignments
          @setting_assignments = {}.compare_by_identity
          scope(block, owner.path) do
            block.children.each { |child| parse_block(child, owner) }
            if owner.kind == :service_templates && @setting_assignments.values.any? { |fields| fields.values.any? { |entry| entry[:conflicted] } }
              owner.record[:authentication_type] = nil
            else
              owner.finish
            end
            owner.record
          end
        ensure
          @setting_assignments = previous_assignments
        end

        # 等价重复不改变完整性；同块冲突删除事实，并使原始来源和后续声明失效。
        def assign_setting(record, key, value, block)
          assign_settings(record, key, { key => value }, block)
        end

        # 一条命令的关联字段共享身份，冲突时整体排除，不能留下残缺派生标志。
        def assign_settings(record, identity, values, block)
          fields = (@setting_assignments[record] ||= {})
          previous = fields[identity]
          if previous && (previous[:conflicted] || previous[:value] != values)
            (previous[:value].keys | values.keys).each { |key| record.delete(key) }
            cursor.mark(previous[:block].index, state: :invalid)
            cursor.mark(block.index, state: :invalid)
            @issues << { code: :conflicting_configuration_value, line: block.line, first_line: previous[:block].line }
            previous[:conflicted] = true
          else
            fields[identity] ||= { value: values, block: block }
            record.merge!(values)
          end
        end

        # 未声明的可选 VLAN 保持未知，已声明值须在设备 VLAN 范围内。
        def configured_vlan(raw)
          vlan = Fields.integer(raw, max: 4094)
          raise ArgumentError, "Invalid configured VLAN" if vlan && vlan.zero?
          vlan
        end

        # 将已识别的无线设置应用到当前作用域记录。
        def apply(scope, block, config)
          line = block.text
          owner, kind, record = scope.record, scope.kind, scope.settings
          words = line.split
          enabled = !line.start_with?("undo ")
          case line
          when /\A(?:undo )?region-code-lock enable\z/
            return false unless kind == :global_configuration
            assign_setting(record, :region_code_lock, enabled, block)
          when /\Anas-id (\S+)\z/
            return false unless kind == :global_configuration
            assign_setting(record, :nas_id, Regexp.last_match(1), block)
          when /\A(?:undo )?rrop anti-bmc network (ipv4-and-ipv6-simple) enable\z/
            return false unless kind == :ap_groups
            assign_setting(record[:rrop_anti_bmc] ||= {}, :network, { mode: Regexp.last_match(1), enabled: enabled }, block)
          when /\Arrop anti-bmc default-action (deny|permit)\z/
            return false unless kind == :ap_groups
            assign_setting(record[:rrop_anti_bmc] ||= {}, :default_action, Regexp.last_match(1), block)
          when /\Aserial-id (\S+)\z/
            return false unless %i[access_points ap_groups].include?(kind)
            kind == :ap_groups ? owner[:serial_ids] << words.last : assign_setting(record, :serial_id, words.last, block)
          when /\Aap (\S+)\z/
            return false unless kind == :ap_groups
            owner[:ap_names] << words.last
          when /\Avlan (\d+)\z/
            vlan = configured_vlan(words.last)
            kind == :ap_groups ? owner[:vlan_ids] << vlan : assign_setting(owner, :vlan_id, vlan, block)
          when /\Assid (.+)\z/
            return false unless kind == :service_templates
            assign_setting(owner, :ssid, Regexp.last_match(1), block)
          when /\A(?:undo )?service-template enable\z/
            return false unless kind == :service_templates
            assign_setting(owner, :enabled, enabled, block)
          when /\Aservice-template (\S+)(?: vlan (\d+))?\z/
            return false unless kind == :radio
            name, vlan = Regexp.last_match.captures
            @configuration.bind_template(record, name, configured_vlan(vlan))
          when /\Apreshared-key\s+.+\z/i
            assign_setting(record, :has_preshared_key, true, block)
          when /\Aakm mode (.+)\z/
            assign_setting(record, :akm_modes, Regexp.last_match(1).downcase.gsub("802.1x", "dot1x").split, block)
          when /\A(cipher-suite|security-ie) (.+)\z/
            key = words.first == "cipher-suite" ? :cipher_suites : :security_ies
            assign_setting(record, key, words.drop(1).map(&:downcase), block)
          when /\Aclient-security authentication-mode (.+)\z/
            mode = Regexp.last_match(1).downcase
            unless %w[dot1x mac mac-and-dot1x dot1x-then-mac mac-then-dot1x oui-then-dot1x].include?(mode)
              raise ArgumentError, "Invalid client authentication mode"
            end
            assign_setting(record, :client_security_authentication_mode, mode, block)
          when /\Aclient-security (ignore-authentication|ignore-authorization)\z/
            assign_setting(record, words.last.tr("-", "_").to_sym, true, block)
          when /\A(dot1x|mac-authentication) domain (\S+)\z/
            assign_setting(record, "#{words.first.tr('-', '_')}_domain".to_sym, words.last, block)
          when /\Aportal (enable method|domain|bas-ip|apply web-server|apply mac-trigger-server) (\S+)\z/
            key, value = Regexp.last_match.captures
            # 仅保留 Portal 是否存在；URL 与凭据不属于无线清单契约。
            assign_setting(record[:portal] ||= {}, key.tr(" -", "__").to_sym, value.include?("://") ? true : value, block)
          when /\A(?:undo )?(dot1x|mac-authentication)\z/
            assign_setting(record, "#{Regexp.last_match(1).tr('-', '_')}_enabled".to_sym, enabled, block)
          when /\Adot1x authentication-method (chap|eap|pap)\z/
            assign_setting(record, :dot1x_authentication_method, Regexp.last_match(1), block)
          when /\Amac-authentication user-name-format fixed(?: account \S+)?(?: password (simple|cipher) \S+)?\z/
            # 固定账号的明文和密文均不进入普通事实或捕获快照。
            storage = Regexp.last_match(1)
            assign_settings(record, :mac_username_setting,
              { mac_authentication_user_name_format: "fixed", mac_authentication_has_password: !storage.nil? }, block)
          when /\Amac-authentication user-name-format (mac-address(?: (?:with-hyphen|without-hyphen))?(?: (?:lowercase|uppercase))?)\z/
            assign_settings(record, :mac_username_setting, { mac_authentication_user_name_format: Regexp.last_match(1) }, block)
          when /\Adot1x timer (supp-timeout|tx-period) (\d+)\z/
            assign_setting(record[:dot1x_timers] ||= {}, words[2].tr("-", "_").to_sym, Fields.integer(words.last), block)
          when /\Awlan (?:client-security )?static-(black|white)list mac-address (\S+)(?: (.+))?\z/
            kind, mac, reason = Regexp.last_match.captures
            config[kind == "black" ? :blacklist : :whitelist] << { mac_address: Fields.mac_address(mac), reason: reason }
          when /\A(?:undo )?(?:wlan )?(auto-ap|auto-persistent|band-navigation|client inspect|radio-load-balance band-navigation) enable\z/
            assign_setting(record, Regexp.last_match(1).tr(" -", "__").to_sym, enabled, block)
          when /\A(?:undo )?(beacon ssid-hide|bss transition-management enable)\z/
            assign_setting(record, line.include?("ssid-hide") ? :ssid_hidden : :btm_enabled, enabled, block)
          when /\A(client keep-alive|client-rate-limit|firmware-upgrade|radio) (enable|disable)\z/
            key = { "client keep-alive" => :client_keep_alive, "client-rate-limit" => :client_rate_limit_enabled,
              "firmware-upgrade" => :firmware_upgrade, "radio" => :enabled }.fetch(Regexp.last_match(1))
            assign_setting(record, key, words.last == "enable", block)
          when /\A(client keep-alive interval|client max-count|client cache aging-time|bss transition-management disassociation forced timer|statistics-interval|priority|dot1x retry|wlan tcp mss) (\d+)\z/
            key = { "client keep-alive interval" => :client_keep_alive_interval, "client max-count" => :client_max_count,
              "client cache aging-time" => :client_cache_aging_time, "bss transition-management disassociation forced timer" => :btm_disassociation_timer,
              "statistics-interval" => :statistics_interval, "priority" => :priority, "dot1x retry" => :dot1x_retry, "wlan tcp mss" => :tcp_mss }.fetch(Regexp.last_match(1))
            assign_setting(record, key, Fields.integer(words.last), block)
          when /\A(?:description|map-configuration) (.+)\z/
            assign_setting(record, words.first.tr("-", "_").to_sym, words.drop(1).join(" "), block)
          when /\Abackup-ac ip (\S+)\z/ then assign_setting(record, :backup_ac_ip, Fields.ip_address(words.last), block)
          when /\Achannel band-width (.+)\z/ then assign_setting(record, :channel_bandwidth, Regexp.last_match(1), block)
          when /\Achannel auto unlock\z/
            assign_settings(record, :channel_setting, { channel: "auto", channel_number: nil, channel_unlocked: true }, block)
          when /\Achannel (.+)\z/
            channel = Regexp.last_match(1)
            channel_number = Fields.channel(channel)
            assign_settings(record, :channel_setting, { channel: channel, channel_number: channel_number }, block)
          when /\Amax-power (\d+(?:\.\d+)?)\z/ then assign_setting(record, :max_power, Fields.number(words.last), block)
          when /\Aclient-rate-limit (inbound|outbound) mode (\S+) cir (\d+)\z/
            assign_setting(record[:client_rate_limit] ||= {}, words[1].to_sym, { mode: words[3], cir_bps: Fields.integer(words.last) * 1000 }, block)
          when /\Arate (mandatory|supported|disabled|multicast) (.+)\z/
            assign_setting(record[:rates] ||= {}, words[1].to_sym, words[1] == "multicast" ? words.drop(2).join(" ") : words.drop(2).map { |word| Fields.number(word) }, block)
          when /\Aoption client (reject|reconnect) enable rssi (-?\d+(?:\.\d+)?)\z/
            assign_setting(record[:client_options] ||= {}, words[2].to_sym, Fields.number(words.last), block)
          when /\Asacp anti-sticky enable(?: rssi (-?\d+(?:\.\d+)?))? interval (\d+)\z/
            signal, interval = Regexp.last_match.captures
            assign_setting(record, :anti_sticky, { enabled: true, rssi: Fields.number(signal), interval: Fields.integer(interval) }, block)
          when /\Apacket-filter name (\S+) (inbound|outbound)\z/
            assign_setting(record[:packet_filters] ||= {}, words.last.to_sym, words[2], block)
          when /\A(?:client forwarding-location|wlan image-load filepath|wlan fast-forwarding mode|led-mode) (\S+)\z/
            key = { "client" => :forwarding_location, "wlan image-load" => :image_load_filepath,
              "wlan fast-forwarding" => :fast_forwarding_mode, "led-mode" => :led_mode }
            assign_setting(record, key.fetch(words.first == "wlan" ? words.take(2).join(" ") : words.first), words.last, block)
          when /\A(local|member) ip (\S+)\z/
            words.first == "local" ? assign_setting(record, :local_ip, Fields.ip_address(words.last), block) : (record[:member_ips] ||= []) << Fields.ip_address(words.last)
          when /\Aclient-mac (\S+)\z/ then (record[:mac_addresses] ||= []) << Fields.mac_address(words.last)
          when "wlan tunnel-preempt enable" then assign_setting(record, :tunnel_preempt, true, block)
          when "broadcast-probe reply disable" then assign_setting(record, :broadcast_probe_reply, false, block)
          when "radar-detect disable" then assign_setting(record, :radar_detect_disabled, true, block)
          when "calibrate-channel self-decisive enable all" then assign_setting(record, :calibrate_channel, true, block)
          when "calibrate-power self-decisive enable all" then assign_setting(record, :calibrate_power, true, block)
          when "ap-license-synchronization enable" then assign_setting(record, :license_synchronization, true, block)
          else return false
          end
          true
        end
      end
    end
  end
end
