# frozen_string_literal: true

source "https://rubygems.org"
gemspec

gem "rake"
gem "rspec-core"
gem "rspec-expectations"
gem "rspec-mocks"
gem "rubocop-rails-omakase", require: false

# CLI 传输及环境文件保持为可选依赖，纯解析安装无需它们。
group :examples do
  gem "net-connector", ">= 0.21.0", "< 0.23", require: false
end

gem "ctx_driver", ">= 0.2.2"

# 公共业务层候选源码联调；发布包仍使用 gemspec 中的版本依赖。
gem "ctx_runner", path: ENV.fetch("CTX_RUNNER_PATH") if ENV["CTX_RUNNER_PATH"]

# 公共 CLI 候选源码联调；安装包不探测相邻源码。
gem "ctx_cli", path: ENV.fetch("CTX_CLI_PATH") if ENV["CTX_CLI_PATH"]
