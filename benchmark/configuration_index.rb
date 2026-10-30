# frozen_string_literal: true

require "wireless/change_plan"
require "json"

# 同一输入对比逐候选扫描与一次索引；包含索引构造，并验证候选集合相同。
puts JSON.generate(ruby: RUBY_DESCRIPTION, source: Wireless::ConfigurationIndex.instance_method(:initialize).source_location)
[ 500, 1000, 2000 ].each do |count|
  changes = (1..count).map do |index|
    { "kind" => "wireless_security", "name" => "T#{index}", "enabled" => true,
      "cipher_suites" => %w[ccmp tkip], "security_ies" => %w[rsn wpa] }
  end
  config = { "service_templates" => changes.map do |change|
    { "name" => change["name"], "enabled" => true, "configuration" => change.slice("cipher_suites", "security_ies") }
  end }
  results = {}
  %i[scan index].each do |mode|
    results[mode] = 3.times.map do
      GC.start
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      index = Wireless::ConfigurationIndex.new(config) if mode == :index
      selected = changes.select do |change|
        Wireless::ChangePlan.render(change)
        matches = mode == :scan ? config["service_templates"].select { |template| template["name"] == change["name"] } : [ index.template(change["name"]) ].compact
        matches.one? && matches.first["enabled"] == change["enabled"] &&
          %w[cipher_suites security_ies].all? { |key| matches.first.dig("configuration", key) == change[key] }
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      allocations = GC.stat(:total_allocated_objects) - allocated
      raise "Candidate semantics changed" unless selected == changes
      { milliseconds: (elapsed * 1000).round(3), allocations: allocations }
    end
  end
  puts JSON.generate(templates: count, samples: results)
end
