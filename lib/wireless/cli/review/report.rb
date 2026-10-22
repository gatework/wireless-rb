# frozen_string_literal: true

require "digest"
require "ctx_runner/fingerprint"
require_relative "../../recommendations"
require_relative "../../change_plan"

module Wireless
  module CLI
    class Review
      # 复用宿主的私有目录与原子发布，候选配置始终加注释保存，防止整文件直接下发。
      module Report
        # 保存独立建议及只读核查脚本；源文件哈希用于变更前核对证据。
        def write_review(document, basename:, source:, source_sha256:, advice: nil)
          raise ArgumentError, "非法报告名称" unless basename.match?(/\A[A-Za-z0-9_.-]+\z/)
          folder = File.join(directory, "recommendations")
          prepare_directory(folder)
          advice ||= Recommendations.new(document).call
          advice = report_advice(advice).merge(source: source, source_sha256: source_sha256)
          prefix = "recommendations/#{basename}"
          publish("#{prefix}.json", JSON.pretty_generate(advice) + "\n")
          publish("#{prefix}.txt", review_text(advice))
          publish("#{prefix}.verify.cli", advice[:items].flat_map { |item| item[:verify] }.compact.uniq.join("\n") + "\n")
          (@scripts ? %i[commands rollback] : []).each do |kind|
            lines = [ "REVIEW ONLY - 未执行；先审阅同名 TXT 报告中的条件、影响和证据 SHA256。", "回退仅在确认本次增量已生效、无其他变更时使用。" ]
            advice[:items].each do |item|
              next if item[kind].empty?
              lines << "#{item[:code]} / #{item[:scope]}"
              lines.concat(item[kind])
            end
            # 配置文件全部注释化；JSON/TXT 保留原始候选命令以便逐项审阅。
            suffix = kind == :commands ? "suggested.cfg" : "rollback.cfg"
            publish("#{prefix}.#{suffix}", lines.map { |line| "! #{line}" }.join("\n") + "\n")
          end
          if @scripts
            # 外部建议不能替代来源完整性；只有唯一完整配置才能绑定可执行计划。
            observation = document.dig("snapshot", "dimensions", "configuration")
            records = observation && observation["records"]
            config = records.first if observation && observation["status"] == "complete" && records.is_a?(Array) && records.one? && records.first.is_a?(Hash)
            config_sha256 = nil
            advice[:items].each_with_index do |item, index|
              next unless config && item[:status] == "candidate" && item[:change] && ChangePlan.eligible?(config, item[:change])
              commands, rollback = ChangePlan.render(item[:change])
              config_sha256 ||= CtxRunner::Fingerprint.call(config)
              plan = { schema_version: 1, platform: "h3c_wireless", device: document.fetch("device"), expected_config_sha256: config_sha256,
                source: source, source_sha256: source_sha256, change: item[:change], commands: commands, rollback: rollback,
                scope: item[:scope], title: item[:title], prerequisites: item[:prerequisites], impact: item[:impact], verify: item[:verify] }
              publish("#{prefix}.#{index + 1}.plan.json", JSON.pretty_generate(plan) + "\n")
            end
          end
          { device: advice[:device], counts: advice[:counts], report: "#{prefix}.txt", source: source, source_sha256: source_sha256 }
        end

        # 离线摘要先写未完成检查点，完成所有正文后才确认生成成功。
        def finish_review(entries, source_batch:)
          counts = entries.each_with_object(Hash.new(0)) { |entry, total| entry[:counts].each { |key, count| total[key] += count } }
          summary = { status: "incomplete", review_only: true, devices: entries.size, counts: counts, source_batch: source_batch, reports: entries }
          checkpoint("review.json", summary)
          lines = [ "WIRELESS 修复建议", "", "仅生成建议，未执行设备变更。candidate 需要确认条件；blocked 需要补齐参数；investigate 为排查或补采任务。", "", "设备：#{entries.size}；建议分类：#{counts}", "", "未命中规则不代表网络健康；本次不推断跨设备 Fabric 归属或完整业务基线。", "" ]
          entries.each do |entry|
            device = entry[:device] || {}
            lines << "#{device['name']}（#{device['host']}）：#{entry[:counts]}；报告：#{entry[:report]}"
          end
          publish("review.txt", lines.join("\n") + "\n")
          finalize("review.json", summary.merge(status: "complete"), checkpoint: summary)
        end

        private

        # 默认报告只有诊断与验证；配置草稿必须由 --scripts 显式请求。
        def report_advice(advice)
          return advice if @scripts
          advice.merge(items: advice[:items].map { |item| item.reject { |key, _| %i[change template].include?(key) }.merge(commands: [], rollback: []) })
        end

        # 正文将可执行语法与未补齐的模板分开，证据使用 JSON 保持可追溯性。
        def review_text(advice)
          device = advice[:device] || {}
          lines = [ "#{device['name']}（#{device['host']}）修复建议", "", "仅供审阅，未执行。证据时间：#{advice[:observed_at] || '未知'}；来源：#{advice[:source]}", "", "源文件 SHA256：#{advice[:source_sha256]}", "", "先重采确认配置未变化，再逐项确认前提；禁止整批直接粘贴。回退前确认本次变更实际生效且无并行修改。", "" ]
          lines << "当前规则没有命中；不代表网络健康或已覆盖所有配置问题。" if advice[:items].empty?
          advice[:items].each do |item|
            lines.concat([ "#{item[:title]} — #{item[:scope]}", "", "状态：#{item[:status]}；规则：#{item[:code]}；类别：#{item[:category]}", "" ])
            lines.concat([ "影响：#{item[:impact]}", "" ]) if item[:impact]
            lines.concat([ "依据：", "", JSON.pretty_generate(item[:evidence]), "" ])
            { prerequisites: "适用条件", blockers: "待补信息", commands: "候选配置（未执行）", rollback: "条件回退", verify: "只读核查 / 验收命令", template: "待补参数模板（不可执行）" }.each do |key, label|
              values = item[key] || []
              next if values.empty?
              lines.concat([ "#{label}：", "" ])
              lines.concat(values.map { |value| "  #{value}" })
              lines << ""
            end
            lines.concat([ "验收：#{item[:expected]}", "", "命令参考：#{item[:references].join(' ')}", "" ])
          end
          lines.join("\n") + "\n"
        end
      end
    end
  end
end
