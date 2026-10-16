# frozen_string_literal: true

require_relative "runtime_parser"

module Wireless
  # 保留 H3C 公共入口，具体 CLI 语法由独立命令类负责。
  class H3cRuntime
    # 绑定 H3C 运行解析器，并保留既有公共入口。
    def initialize(model: nil)
      @parser = RuntimeParser.new(model: model)
    end

    # 将单个 H3C 运行维度委派给共享无线解析入口。
    def parse(name, text, complete:)
      @parser.parse(name, text, platform: :h3c, complete: complete)
    end
  end
end
