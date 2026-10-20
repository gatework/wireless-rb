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
  gem "net-connector", "~> 0.14.2", require: false
end

gem "ctx_driver", ">= 0.2.2"
