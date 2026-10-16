# frozen_string_literal: true

require "bundler/setup"
require "rspec/core"
require "wireless"

# 共享配置、运行与嵌套会话示例的测试断言。
module WirelessSpecHelpers
  # 先断言只有一条记录，再返回该记录。
  def only_record(records)
    expect(records.size).to eq(1)
    records.fetch(0)
  end
end

RSpec.configure do |config|
  config.include WirelessSpecHelpers
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand config.seed
end
