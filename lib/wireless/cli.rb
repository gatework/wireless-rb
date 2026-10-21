# frozen_string_literal: true

require "wireless/version"

module Wireless
  # 命令入口按需加载采集或解析实现；核心库无需加载 CLI。
  module CLI
    # 由调用方拥有退出行为，库入口只返回退出码。
    def self.run(argv, env: ENV, out: $stdout, error: $stderr, input: $stdin, **collect_options)
      arguments = argv.dup
      command = arguments.shift
      case command
      when nil, "--help", "--help-all", "-h"
        return usage(out) if arguments.empty?
      when "--version", "-v"
        return out.puts(Wireless::VERSION) || 0 if arguments.empty?
      when "collect"
        begin
          require_relative "cli/collect"
        rescue LoadError
          error.puts "collect 需要含共享清单筛选的当前 net-connector；请安装项目依赖。"
          return 2
        end
        return Collect.new(env: env, out: out, error: error, input: input, **collect_options).run(arguments)
      when "apply"
        require_relative "cli/apply"
        return Apply.new(env: env, out: out, error: error, input: input, connector_factory: collect_options[:connector_factory], discovery: collect_options.fetch(:discovery, {})).run(arguments)
      when "review"
        require_relative "cli/review"
        return Review.new(out: out, error: error).run(arguments)
      when "parse"
        require_relative "cli/parse"
        return Parse.new(out: out, error: error, input: input, command: collect_options.fetch(:command, "wireless parse")).run(arguments)
      end
      error.puts "未知命令或多余参数；使用 wireless --help 查看用法"
      2
    end

    # 全局帮助不读取配置、环境文件或设备清单。
    def self.usage(out)
      out.puts "用法：wireless collect [选项]  只读采集与报告\n      wireless parse [选项]    离线文件或 stdin 解析\n      wireless review --batch DIR  离线修复建议\n      wireless apply --plan FILE  交互确认后下发\n      wireless --version\n使用 wireless collect --help 、wireless parse --help 或 wireless review --help 查看参数；--help-all 查看完整约定，--examples 查看范例。"
      0
    end
    private_class_method :usage
  end
end
