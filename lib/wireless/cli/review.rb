# frozen_string_literal: true

require "optparse"
require "json"
require "digest"
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
        options = {}
        parser = OptionParser.new do |p|
          p.banner = "用法：wireless review --batch DIR [--output DIR]（离线生成建议，不执行配置）"
          p.on("--batch DIR", "已采集批次，含 devices/*.json") { |value| options[:batch] = value }
          p.on("--[no-]scripts", "可选导出配置建议，默认仅诊断") { |value| options[:scripts] = value }
          p.on("--output DIR", "私有输出根目录，默认批次内 reviews") { |value| options[:output] = value }
          p.on("-h", "--help", "查看帮助") { options[:help] = true }
        end
        rest = parser.parse(argv.dup)
        return @out.puts(parser) || 0 if options[:help]
        raise ArgumentError, "需要批次目录" unless rest.empty? && options[:batch]
        batch = File.expand_path(options[:batch])
        paths = Dir[File.join(batch, "devices", "*.json")].sort
        raise ArgumentError, "无设备报告" if paths.empty?
        # 先校验所有输入，损坏文件不会留下看似完成的部分建议批次。
        documents = paths.map do |path|
          body = File.read(path)
          document = JSON.parse(body)
          validate(document)
          [ path, body, document, Recommendations.new(document).call ]
        end
        report = CLI::Report.new(options[:output] || File.join(batch, "reviews"), scripts: options[:scripts] == true)
        entries = documents.each_with_index.map do |(path, body, document, advice), index|
          basename = "#{index + 1}-#{File.basename(path, '.json').gsub(/[^A-Za-z0-9_.-]/, '_')[0, 160]}"
          report.write_review(document, basename: basename, source: path, source_sha256: Digest::SHA256.hexdigest(body), advice: advice)
        end
        report.finish_review(entries, source_batch: batch)
        @out.puts "建议已生成：#{report.directory}/review.txt；#{entries.size} 台；未执行设备变更。"
        0
      rescue OptionParser::ParseError, ArgumentError, TypeError, KeyError, JSON::ParserError, SystemCallError, IOError => error
        @error.puts "建议生成失败（#{error.class.name}）；请检查输入结构、目录权限和 --help；未执行设备变更。"
        2
      end

      private

      # 仅接受宿主保存的设备快照边界；缺少快照的失败采集仍可生成补采任务。
      def validate(document)
        raise ArgumentError, "无设备身份" unless document.is_a?(Hash) && document["device"].is_a?(Hash) && %w[name host].all? { |key| document["device"][key].is_a?(String) }
        snapshot = document["snapshot"]
        raise ArgumentError, "无快照字段" unless document.key?("snapshot")
        return if snapshot.nil?
        raise ArgumentError, "快照结构错误" unless snapshot.is_a?(Hash) && snapshot["dimensions"].is_a?(Hash)
        snapshot["dimensions"].each do |dimension, observation|
          unless observation.is_a?(Hash) && %w[complete partial failed unsupported not_requested].include?(observation["status"]) && observation["records"].is_a?(Array) && observation["records"].all? { |record| record.is_a?(Hash) }
            raise ArgumentError, "观测结构错误"
          end
          array_of_hashes(observation.fetch("issues", []))
          observation["records"].each { |record| validate_record(record, dimension) }
        end
      end

      # 校验规则读取的容器类型，错误消息不包含配置正文。
      def array_of_hashes(value)
        raise ArgumentError, "列表结构错误" unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(Hash) }
        value
      end

      # 映射值必须仍是记录，不能将损坏结构解释成空事实。
      def hash_of_hashes(value)
        raise ArgumentError, "映射结构错误" unless value.is_a?(Hash) && value.values.all? { |entry| entry.is_a?(Hash) }
        value
      end

      # 在输出目录创建前验证所有会参与建议生成的嵌套字段。
      def validate_record(record, dimension)
        if dimension == "access_points"
          state = record["operational_status"]
          raise ArgumentError, "AP 状态结构错误" unless state.nil? || state.is_a?(String)
        end
        return unless dimension == "configuration"
        hash_of_hashes(record.fetch("access_points", {}))
        array_of_hashes(record.fetch("ap_groups", []))
        array_of_hashes(record.fetch("service_templates", [])).each do |template|
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
