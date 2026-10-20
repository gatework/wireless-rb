# frozen_string_literal: true

require "wireless"
require "json"

# 合成输入仅测本地解析；同时核对完整性、事实数量和续行内容。
def measure(expected:)
  samples = 3.times.map do
    GC.start
    allocations = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    actual = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    allocated = GC.stat(:total_allocated_objects) - allocations
    raise "Unexpected benchmark result: #{actual.inspect}" unless actual == expected

    { milliseconds: (elapsed * 1000).round(3), allocations: allocated }
  end
  samples.min_by { |sample| sample[:milliseconds] }
end

# 大型 LF 回显同时验证完整扫描与首行失败的短路路径。
terminal_body = "AP name: synthetic\n" * 100_000
{ "terminal_full_scan" => [ terminal_body, false ],
  "terminal_first_error" => [ "Unrecognized command\n" + terminal_body, true ] }.each do |name, (text, expected)|
  stats = measure(expected: expected) { Wireless::Terminal.unsupported?(text) }
  puts JSON.generate(case: name, count: 100_000, **stats)
end

[ 500, 2000, 5000 ].each do |count|
  templates = (1..count).map { |index| "wlan service-template T#{index}\n ssid T#{index}\n#\n" }.join + "return\n"
  stats = measure(expected: [ :complete, count ]) do
    result = Wireless::Config.new.parse(templates, complete: true)
    [ result.status, result.records.first.fetch(:service_templates).size ]
  end
  puts JSON.generate(case: "service_templates", count: count, **stats)

  bindings = "wlan ap AP model TEST\n radio 1\n" +
    (1..count).map { |index| "  service-template T#{index} vlan 100\n" }.join + "return\n"
  stats = measure(expected: [ :complete, count ]) do
    result = Wireless::Config.new.parse(bindings, complete: true)
    [ result.status, result.records.first.dig(:access_points, "AP", :radios, "1", :service_templates).size ]
  end
  puts JSON.generate(case: "template_bindings", count: count, **stats)

  description = "synthetic device description " * 3
  neighbors = "LLDP neighbor-information of port 1[GE1]:\nLLDP neighbor index: 1\n" \
    "Chassis ID: Device-A\nPort ID: GE2\nSystem description: base\n" + ("  #{description}\n" * count)
  expected = "base" + ("\n#{description.strip}" * count)
  stats = measure(expected: [ :complete, true ]) do
    result = Wireless::NeighborParser.new.parse(neighbors, ap_name: "AP", complete: true)
    [ result.status, result.records.first.dig(:details, :system_description) == expected ]
  end
  puts JSON.generate(case: "lldp_continuations", count: count, **stats)
end
