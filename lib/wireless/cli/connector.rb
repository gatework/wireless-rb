# frozen_string_literal: true

module Wireless
  module CLI
    # 可选传输适配器；只由联网采集使用，解析库不引用 net-connector。
    class Connector
      # 固定设备与接入选项，不在构造时建立会话。
      def initialize(device, settings)
        @device, @settings = device, settings
      end

      # 向 Collector 声明已知平台，不把品牌猜测当作型号识别。
      def platform = @device.fetch("platform").to_sym

      # 每个任务独占新会话；AP 适配器自行取得嵌套操作租约，不能再套不可重入的外层租约。
      def open
        vendor = platform == :h3c ? :h3c_wireless : platform
        Net::Connector.open(vendor, host: @device.fetch("host"), **@settings) do |native|
          yield native
        end
      end
    end
  end
end
