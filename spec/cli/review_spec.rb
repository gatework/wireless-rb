# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli"
require "wireless/cli/report"
require "tmpdir"
require "stringio"
require "digest"

RSpec.describe "Wireless offline review" do
  it "accepts the actual parser configuration schema including the AP map" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "devices"))
      observation = Wireless::Config.new.parse("wlan ap ap1 model WA6530\n radio 1\n  service-template missing vlan 10\n#\n", complete: true)
      File.write(File.join(root, "devices", "ac.json"), JSON.generate(device: { name: "AC", host: "192.0.2.1", platform: "h3c_wireless" }, snapshot: { dimensions: { configuration: observation.to_h } }))
      error = StringIO.new
      expect(Wireless::CLI.run([ "review", "--batch", root ], error: error, out: StringIO.new)).to eq(0), error.string
      advice = JSON.parse(File.read(Dir[File.join(root, "reviews", "*", "recommendations", "*.json")].fetch(0)))
      expect(advice["items"]).to include(include("code" => "service_template_missing"))
    end
  end

  it "reviews saved facts without changing the source and binds recommendations to its hash" do
    Dir.mktmpdir do |root|
      batch = File.join(root, "source")
      Dir.mkdir(batch)
      Dir.mkdir(File.join(batch, "devices"))
      source = File.join(batch, "devices", "leaf.json")
      body = JSON.generate(device: { name: "LEAF", host: "192.0.2.1", platform: "h3c_wireless" }, snapshot: { dimensions: { configuration: { status: "partial", records: [], issues: [] } } })
      File.write(source, body)
      out, error = StringIO.new, StringIO.new
      status = Wireless::CLI.run([ "review", "--batch", batch, "--output", File.join(root, "out") ], out: out, error: error)
      expect(status).to eq(0), error.string
      expect(File.read(source)).to eq(body)
      directory = File.dirname(Dir[File.join(root, "out", "*", "review.json")].fetch(0))
      summary = JSON.parse(File.read(File.join(directory, "review.json")))
      expect(summary).to include("status" => "complete", "review_only" => true, "devices" => 1)
      expect(out.string).to include("#{directory}/review.txt")
      expect(summary.fetch("reports").first.fetch("report")).to end_with(".txt")
      text = File.read(File.join(directory, "review.txt"))
      expect(text).to include("WIRELESS 修复建议", summary.fetch("reports").first.fetch("report"))
      expect(text).not_to match(/^#|```|\[[^\]]+\]\([^)]+\)/)
      review = JSON.parse(File.read(Dir[File.join(root, "out", "*", "recommendations", "*.json")].fetch(0)))
      expect(review).to include("source_sha256" => Digest::SHA256.hexdigest(body))
      expect(review["items"]).to include(include("code" => "evidence_incomplete"))
      expect(Dir[File.join(root, "out", "**", "*.md")]).to be_empty
      Dir[File.join(root, "out", "**", "*")].select { |path| File.file?(path) }.each do |path|
        expect(File.stat(path).mode & 0o777).to eq(0o600)
      end
    end
  end

  it "rejects malformed input without printing its sensitive content or a completed manifest" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "devices"))
      File.write(File.join(root, "devices", "broken.json"), "private-password-invalid-json")
      out, error = StringIO.new, StringIO.new
      expect(Wireless::CLI.run([ "review", "--batch", root, "--output", File.join(root, "out") ], out: out, error: error)).to eq(2)
      expect(error.string).not_to include("private-password")
      expect(Dir[File.join(root, "out", "*", "review.json")]).to be_empty
    end
  end

  it "automatically includes advice in new collection reports" do
    Dir.mktmpdir do |root|
      report = Wireless::CLI::Report.new(File.join(root, "out"))
      report.write({ device: { "name" => "LEAF", "host" => "192.0.2.1", "platform" => "h3c_wireless" }, status: :failed, dimensions: {} })
      document = JSON.parse(File.read(Dir[File.join(report.directory, "devices", "*.json")].fetch(0)))
      expect(document.fetch("recommendations")).to include("review_only" => true)
      recommendation = Dir[File.join(report.directory, "recommendations", "*.txt")].fetch(0)
      text = File.read(Dir[File.join(report.directory, "devices", "*.txt")].fetch(0))
      expect(text).to include("recommendations/#{File.basename(recommendation)}")
      expect(Dir[File.join(report.directory, "**", "*.md")]).to be_empty
    end
  end
  it "finishes advice publication when another worker creates the recommendation directory first" do
    Dir.mktmpdir do |root|
      report = Wireless::CLI::Report.new(File.join(root, "out"))
      folder = File.join(report.directory, "recommendations")
      # 在第一次 mkdir 的边界插入另一 worker 的创建，确定性重现检查后的竞态。
      allow(Dir).to receive(:mkdir).and_wrap_original do |original, path, *args, **kwargs|
        original.call(path, *args, **kwargs) if path == folder && !File.directory?(folder)
        original.call(path, *args, **kwargs)
      end
      2.times do |index|
        report.write({ device: { "name" => "WLC#{index}", "host" => "192.0.2.#{index + 1}", "platform" => "h3c_wireless" }, status: :failed, dimensions: {} })
      end
      expect(Dir[File.join(folder, "*.txt")].size).to eq(2)
      expect(Dir[File.join(folder, "*.json")].size).to eq(2)
      expect(File.stat(folder).mode & 0o777).to eq(0o700)
    end
  end

  it "rejects malformed nested observations through the normal error channel" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "devices"))
      File.write(File.join(root, "devices", "bad.json"), JSON.generate(device: { name: "test", host: "192.0.2.1" }, snapshot: { dimensions: { configuration: { status: "partial", records: [], issues: "private-password" } } }))
      error = StringIO.new
      expect(Wireless::CLI.run([ "review", "--batch", root ], error: error, out: StringIO.new)).to eq(2)
      expect(error.string).not_to include("private-password")
      expect(Dir[File.join(root, "reviews", "*", "review.json")]).to be_empty
    end
  end

  it "restores an incomplete review manifest if final directory sync fails after rename" do
    Dir.mktmpdir do |root|
      report = Wireless::CLI::Report.new(File.join(root, "reports"))
      original = File.method(:rename)
      renamed = 0
      allow(File).to receive(:rename) do |source, target|
        renamed += 1 if target.end_with?("/review.json")
        original.call(source, target)
      end
      original_open = File.method(:open)
      allow(File).to receive(:open) do |*args, **kwargs, &operation|
        next original_open.call(*args, **kwargs) unless operation
        original_open.call(*args, **kwargs) do |file|
          allow(file).to receive(:fsync).and_raise(Errno::EIO) if renamed == 2 && file.stat.directory?
          operation.call(file)
        end
      end
      expect { report.finish_review([], source_batch: root) }.to raise_error(Wireless::CLI::Report::Error)
      saved = JSON.parse(File.read(File.join(report.directory, "review.json")))
      expect(saved["status"]).to eq("incomplete")
    end
  end
  it "exports configuration drafts only when explicitly requested" do
    Dir.mktmpdir do |root|
      document = { "device" => { "host" => "192.0.2.1", "name" => "test" }, "snapshot" => nil }
      advice = { device: document["device"], items: [ { code: "test", scope: "test", title: "test", status: "candidate", evidence: { "configured" => false }, prerequisites: [ "confirm-prerequisite" ], blockers: [], commands: [ "configuration-command" ], rollback: [ "rollback-command" ], verify: [ "verification-command" ], references: [ "https://example.invalid/commands" ] } ], counts: { "candidate" => 1 } }
      plain = Wireless::CLI::Report.new(File.join(root, "plain"))
      plain.write_review(document, basename: "test", source: "test", source_sha256: "a" * 64, advice: advice)
      expect(Dir[File.join(plain.directory, "recommendations", "*.cfg")]).to be_empty
      expect(File.read(File.join(plain.directory, "recommendations", "test.txt"))).not_to include("configuration-command")
      scripted = Wireless::CLI::Report.new(File.join(root, "scripted"), scripts: true)
      scripted.write_review(document, basename: "test", source: "test", source_sha256: "a" * 64, advice: advice)
      expect(Dir[File.join(scripted.directory, "recommendations", "*.cfg")].size).to eq(2)
      text = File.read(File.join(scripted.directory, "recommendations", "test.txt"))
      expect(text).to include("源文件 SHA256：#{"a" * 64}", "规则：test", '"configured": false',
        "confirm-prerequisite", "configuration-command", "rollback-command", "verification-command", "https://example.invalid/commands")
      expect(text).not_to match(/^#|`|\[[^\]]+\]\([^)]+\)/)
      expect(Dir[File.join(root, "**", "*.md")]).to be_empty
    end
  end
end
