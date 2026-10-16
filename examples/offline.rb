# frozen_string_literal: true

require "wireless"

# 使用合成 H3C AP 回显；配置上限不代表实时功率测量。
output = <<~CLI
  Total number of APs : 1
  AP name : AP-EXAMPLE
  AP ID : 7
  MAC address : 0200-0000-0007
  IP address : 192.0.2.7
  State : Run
  Radio 1 :
   Admin state : Up
   Radio type : 802.11ax 6GHz
   Channel : 1(auto)
   Channel bandwidth : 80MHz
   Operating bandwidth : 40MHz
   Channel usage(%) : 0
   Noise floor : -90 dBm
   Max power : 20
CLI
observations = Wireless::RuntimeParser.new.parse_many(
  %i[access_points radios], output, platform: "h3c", complete: true
)
observations.each do |name, observation|
  puts "#{name}: #{observation.status}, records=#{observation.records.size}"
end
# 两个视图共用一次解析，各自保留完整性状态。
