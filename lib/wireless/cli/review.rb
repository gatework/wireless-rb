# frozen_string_literal: true

require "ctx_cli/command"
require "ctx_cli/review"
require "digest"
require "ctx_runner/evidence"
require_relative "report"

module Wireless
  module CLI
    # 只读打开已有批次，生成独立建议批次；不加载凭据或建立设备连接。
    class Review
      # 注入输出流，离线批次可通过 CLI 或宿主调用。
      def initialize(out: $stdout, error: $stderr)
        @out, @error = out, error
      end

      # 返回零只代表建议生成完成，不代表问题已修复或候选配置已获批准。
      def run(argv)
        command = CtxCli::Command.new(banner: "用法：wireless review --batch DIR [--output DIR]（离线生成建议，不执行配置）", out: @out) do |p, options|
          p.on("--batch DIR", "已采集批次，含 devices/*.json") { |value| options[:batch] = value }
          p.on("--[no-]scripts", "可选导出配置建议，默认仅诊断") { |value| options[:scripts] = value }
          p.on("--output DIR", "私有输出根目录，默认批次内 reviews") { |value| options[:output] = value }
          p.on("-h", "--help", "查看帮助") { options[:help] = true }
        end
        CtxCli::Review.new(command: command, directory: "devices", adapter: self, out: @out, error: @error).run(argv)
      end

      # 领域结构、建议和身份冲突必须在创建输出目录前全部校验。
      def prepare(documents, options)
        documents.each do |entry|
          validate(entry[2])
          entry << Recommendations.new(entry[2]).call
        end
        hosts = documents.map { |entry| entry[2]["device"]["host"] }
        raise ArgumentError, "设备身份重复" unless hosts.uniq == hosts
        nil
      end

      # 公共入口完成预检后才调用发布；领域报告格式保持独立。
      def publish(documents, options, batch:, context:)
        report = CLI::Report.new(options[:output] || File.join(batch, "reviews"), scripts: options[:scripts] == true)
        entries = documents.each_with_index.map do |(path, body, document, advice), index|
          basename = "#{index + 1}-#{File.basename(path, '.json').gsub(/[^A-Za-z0-9_.-]/, '_')[0, 160]}"
          report.write_review(document, basename: basename, source: path, source_sha256: Digest::SHA256.hexdigest(body), advice: advice)
        end
        report.finish_review(entries, source_batch: batch)
        "建议已生成：#{report.directory}/review.txt；#{entries.size} 台；未执行设备变更。"
      end

      private

      # 先校验公共证据外壳，再验证领域记录。
      def validate(document)
        CtxRunner::Evidence.validate(document) { |record, dimension| validate_record(record, dimension) }
      end

      # 在输出目录创建前验证所有会参与建议生成的嵌套字段。
      def validate_record(record, dimension)
        if dimension == "access_points"
          state = record["operational_status"]
          raise ArgumentError, "AP 状态结构错误" unless state.nil? || state.is_a?(String)
        end
        return unless dimension == "configuration"
        CtxRunner::Evidence.map(record.fetch("access_points", {}))
        CtxRunner::Evidence.array(record.fetch("ap_groups", []))
        CtxRunner::Evidence.array(record.fetch("service_templates", [])).each do |template|
          settings = template.fetch("configuration", {})
          raise ArgumentError, "模板结构错误" unless settings.is_a?(Hash)
          %w[cipher_suites security_ies].each do |key|
            values = settings.fetch(key, [])
            raise ArgumentError, "安全配置结构错误" unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) }
          end
        end
      end
    end
  end
end
