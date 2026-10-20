#!/usr/bin/env ruby
# frozen_string_literal: true

# 源码入口只选择本项目库，配置发现和路径解析交由共享加载器。
root = File.expand_path("..", __dir__)
require "bundler/setup" if ENV["BUNDLE_GEMFILE"] && !ENV["BUNDLE_GEMFILE"].empty?
$LOAD_PATH.unshift(File.join(root, "lib"))
require "wireless/cli/collect"

exit Wireless::CLI::Collect.new(command: "ruby bin/wireless.rb").run(ARGV)
