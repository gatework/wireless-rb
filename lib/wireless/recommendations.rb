# frozen_string_literal: true

require "ctx_runner/evidence"
require_relative "h3c/profile"
require_relative "change_plan"
require_relative "fields"

module Wireless
  # 控制器事实与建议分离；配置加固是条件候选，不自动改变无线业务。
  class Recommendations
    REFERENCE = "https://www.h3c.com/en/d_202210/1709621_294551_0.htm"

    # 输入为报告 JSON 的字符串键结构，避免实时与离线流程语义分叉。
    def initialize(document)
      @document = document
      @dimensions = document.dig("snapshot", "observations") || {}
      @h3c = document.dig("target", "platform") == "h3c"
    end

    # 未覆盖的平台明确保留范围限制，不能输出其他厂商的配置命令。
    def call
      items = evidence_tasks
      if @h3c
        config = @dimensions["configuration"] || {}
        if config["status"] == "complete"
          items.concat(config.fetch("records", []).flat_map { |record| record.fetch("service_templates", []).filter_map { |template| security_item(template) } })
          items.concat(config.fetch("records", []).flat_map { |record| binding_tasks(record) })
        end
        items.concat(runtime_tasks)
      else
        items << item("platform_not_supported", "platform", "此平台尚未提供修复规则", evidence: @document.dig("target", "platform"), verify: []).merge(status: "blocked")
      end
      { schema_version: CtxRunner::Evidence::VERSION, kind: "recommendations", review_only: true, health_assessment: "not_performed", target: @document["target"],
        observed_at: @document.dig("snapshot", "observed_at"), items: items, counts: items.map { |entry| entry[:status] }.tally }
    end

    private

    # 每项统一保存最少相关事实、待确认条件及验证步骤。
    def item(code, scope, title, evidence:, verify:, category: "runtime")
      { code: code, scope: scope, title: title, category: category, status: "investigate", evidence: evidence,
        prerequisites: [], blockers: [], commands: [], rollback: [], verify: verify,
        expected: "重采事实并核对业务预期；没有命中建议不代表无线网络健康。", references: [ REFERENCE ] }
    end

    # 只移除已存在的旧协议；必须已有替代协议和明确的启停状态。
    def security_item(template)
      settings = template.fetch("configuration", {})
      ciphers, ies = settings.fetch("cipher_suites", []), settings.fetch("security_ies", [])
      return unless ciphers.include?("tkip") || ies.include?("wpa")
      name = template["name"]
      result = item("legacy_wlan_security", "service-template #{name}", "服务模板保留 TKIP/WPA 兼容配置", category: "configuration",
        evidence: { name: name, enabled: template["enabled"], cipher_suites: ciphers, security_ies: ies },
        verify: [ "display current-configuration", "display wlan client verbose", "display wlan bss all verbose" ])
      result[:prerequisites] = [ "此项是加固建议，不代表当前业务故障；确认所有受影响终端支持 CCMP/RSN，且业务允许移除旧协议。", "核对软件命令支持和模板绑定范围；维护窗口内操作，停用模板会断开相关终端。", "重新采集并确认配置未变化；保留回退脚本。出现异常先回读，勿盲目重放。" ]
      result[:impact] = "停用服务模板会中断所绑定 WLAN 的客户端连接，旧终端可能无法重连。"
      result[:expected] = "保留 CCMP/RSN、模板恢复原启停状态；代表性终端重新关联和认证成功，业务验收通过。"
      unless name.to_s.match?(/\A[A-Za-z0-9_.-]{1,63}\z/) && [ true, false ].include?(template["enabled"]) && ciphers.include?("ccmp") && ies.include?("rsn")
        return result.merge(status: "blocked", blockers: [ "需确认模板启停状态、合法名称、CCMP/RSN 替代配置；缺少任一项不生成变更。" ])
      end
      changes, rollback = [], []
      if ies.include?("wpa")
        changes << " undo security-ie wpa"
        rollback << " security-ie wpa"
      end
      if ciphers.include?("tkip")
        changes << " undo cipher-suite tkip"
        rollback.unshift(" cipher-suite tkip")
      end
      result[:change] = { "kind" => "wireless_security", "name" => name, "enabled" => template["enabled"], "cipher_suites" => ciphers, "security_ies" => ies }
      result.merge(status: "candidate", commands: security_commands(name, changes, template["enabled"]), rollback: security_commands(name, rollback, template["enabled"]))
    end

    # 修改安全参数前停用模板，之后仅恢复原来已启用的模板。
    def security_commands(name, changes, enabled)
      [ "system-view", "wlan service-template #{name}", " undo service-template enable", *changes,
        *(enabled ? [ " service-template enable" ] : []), "quit", "return" ]
    end

    # 完整配置中才判断引用缺失；保留 AP、组、型号、频段的具体作用域。
    def binding_tasks(config)
      templates = config.fetch("service_templates", []).to_h { |template| [ template["name"], template ] }
      references = %w[access_points ap_groups].flat_map { |key| template_references(config.fetch(key, []), key) }
      references.group_by { |reference| reference[:name] }.filter_map do |name, bindings|
        template = templates[name]
        next if template && template["enabled"] != false
        missing = template.nil?
        item(missing ? "service_template_missing" : "bound_service_template_disabled", "service-template #{name}",
          missing ? "AP/组引用了未定义的服务模板" : "已绑定的服务模板被明确禁用", category: "configuration",
          evidence: bindings, verify: [ "display current-configuration", "display wlan bss all verbose" ]).merge(
            status: "blocked", blockers: [ missing ? "需提供模板 SSID、安全认证、转发位置及 VLAN 设计，不能自动创建开放 WLAN。" : "需确认是否有意停用及恢复窗口，不能仅凭绑定关系自动启用业务。" ],
            expected: "所有绑定引用存在且启停状态符合业务意图；运行 BSS 和实际认证验证通过。")
      end
    end

    # 递归只读取显式模板引用，不把不同继承层级直接合并成有效配置。
    def template_references(value, path)
      case value
      when Array
        value.each_with_index.flat_map { |child, index| template_references(child, "#{path}/#{child.is_a?(Hash) ? child.fetch('name', index) : index}") }
      when Hash
        value.flat_map do |key, child|
          if key == "service_templates" && child.is_a?(Array)
            child.filter_map { |entry| { name: entry["name"], path: path, vlan_id: entry["vlan_id"] } if entry.is_a?(Hash) && entry["name"] }
          else
            template_references(child, "#{path}/#{key}")
          end
        end
      else
        []
      end
    end

    # 部分采集不能推导零客户端或配置缺失，指向原始只读命令补采。
    def evidence_tasks
      selected = @dimensions.reject { |name, _| name == "collection" }
      selected = { "configuration" => { "status" => "not_requested" } } if selected.empty?
      selected.filter_map do |name, observation|
        next if observation["status"] == "complete"
        item("evidence_incomplete", name, "证据不完整，先补采", category: "evidence",
          evidence: { status: observation["status"], issues: observation.fetch("issues", []).map { |issue| issue["code"] } },
          verify: @h3c ? Array(H3c::Profile::COMMANDS[name.to_sym]) : [])
      end
    end

    # 正向异常证据即使来自部分回显也保留；历史事件不宣称为当前故障。
    def runtime_tasks
      tasks = []
      conflicts = records("client_ip_conflicts")
      if conflicts.any?
        tasks << item("client_ip_conflict_history", "client_ip_conflicts", "存在历史客户端 IP 冲突记录",
          evidence: conflicts, verify: [ "display wlan statistics client-ip-conflict", "display wlan client verbose", "display arp" ]).merge(
            prerequisites: [ "事件时间不含年份，不据此判断当前仍冲突；先重采并对照新旧 MAC/AP、DHCP 租约、静态地址和漫游记录。", "定位具体地址的两个使用者后，在地址管理源修复重复分配；不自动清表、踢客户端或关闭冲突检测。" ],
            expected: "复核窗口内不再新增同一地址冲突，DHCP/静态地址分配唯一且终端通信正常。")
      end
      offline = records("access_points").select { |ap| Fields.online_status(ap["operational_status"]) == :offline }.map { |ap| ap.slice("name", "ap_id", "operational_status", "management_ip") }
      if offline.any?
        tasks << item("aps_not_running", "access_points", "AP 未处于 Run 状态", evidence: offline, verify: [ "display wlan ap all verbose", "display wlan ap all" ]).merge(
          prerequisites: [ "核对这些 AP 是否应在线；按供电/交换机端口、管理 VLAN/DHCP、CAPWAP 连通性、授权和版本顺序定位，不自动重启。" ])
      end
      down = records("radios").select { |radio| radio["admin_status"].to_s.casecmp?("down") }.map { |radio| radio.slice("ap_name", "radio_id", "admin_status", "protocol") }
      if down.any?
        tasks << item("radios_admin_down", "radios", "存在管理状态 Down 的射频", evidence: down, verify: [ "display wlan ap all verbose", "display current-configuration" ]).merge(
          prerequisites: [ "核对 AP 自身、AP 组及型号配置的继承关系和射频规划；主动关闭频段可能是正常设计，不批量开启。" ])
      end
      tasks
    end

    # 缺少维度与空事实都不会被解释为完整的零记录证明。
    def records(dimension) = @dimensions.fetch(dimension, {}).fetch("records", [])
  end
end
