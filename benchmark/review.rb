# frozen_string_literal: true

require "wireless"
require "wireless/cli/report"
require "json"
require "tmpdir"

# 真实建议与计划序列化，但替换文件发布目标；不包含 fsync、网络或输入构造耗时。
class ReviewBenchmarkSink < Wireless::CLI::Report
  attr_reader :plans

  def publish(relative, body)
    @plans = body if relative == "plan.json"
  end

  def checkpoint(relative, value) = nil
  def finalize(relative, summary, checkpoint:) = summary
end

puts JSON.generate(ruby: RUBY_DESCRIPTION, source: Wireless::CLI::Review::Report.instance_method(:write_review).source_location)
Dir.mktmpdir do |root|
  [ 100, 500, 1000 ].each do |count|
    templates = (1..count).map do |index|
      { "name" => "T#{index}", "ssid" => "test", "enabled" => true,
        "configuration" => { "cipher_suites" => %w[tkip ccmp], "security_ies" => %w[wpa rsn] } }
    end
    config = { "service_templates" => templates }
    document = { "device" => { "name" => "AC", "host" => "192.0.2.1", "platform" => "h3c_wireless" },
      "snapshot" => { "observations" => { "configuration" => { "status" => "complete", "records" => [ config ] } } } }
    expected_digest = CtxRunner::Fingerprint.call(config)
    samples = 3.times.map do
      report = ReviewBenchmarkSink.new(root, scripts: true)
      GC.start
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = report.write_review(document, basename: "AC", source: "synthetic", source_sha256: "a" * 64)
      report.finish_review([ entry ], source_batch: "synthetic")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      objects = GC.stat(:total_allocated_objects) - allocated
      plans = JSON.parse(report.plans).fetch("changes").values
      raise "Lost plans" unless plans.size == count && plans.map { |plan| plan["change"]["name"] } == templates.map { |template| template["name"] }
      raise "Wrong fingerprint" unless plans.all? { |plan| plan["expected_config_sha256"] == expected_digest }
      raise "Lost commands" unless plans.all? { |plan| plan["commands"].include?(" undo cipher-suite tkip") && plan["rollback"].include?(" cipher-suite tkip") }

      { milliseconds: (elapsed * 1000).round(3), allocations: objects }
    end
    puts JSON.generate(templates: count, samples: samples)
  end
end
