# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli"
require "wireless/cli/report"
require "tmpdir"
require "stringio"
require "digest"

RSpec.describe "Wireless offline review" do
  it "rejects oversized source documents before creating reports" do
    require "ctx_cli/input"
    stub_const("CtxCli::Input::MAX_BYTES", 32)
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "devices"))
      File.write(File.join(root, "devices", "large.json"), JSON.generate(schema_version: 3, kind: "collection", device: { name: "AC", host: "192.0.2.1" }, snapshot: nil))
      error = StringIO.new
      expect(Wireless::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: error)).to eq(2)
      expect(File.exist?(File.join(root, "reviews"))).to be(false)
      expect(error.string).not_to include("192.0.2.1")
    end
  end

  it "rejects mismatched and duplicate device identities before creating output" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "devices"))
      path = File.join(root, "devices", "ac.json")
      document = { schema_version: 3, kind: "collection", device: { name: "AC", host: "192.0.2.1" }, snapshot: { collection_status: "complete", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.2" }, observations: {} } }
      File.write(path, JSON.generate(document))
      expect(Wireless::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: StringIO.new)).to eq(2)
      expect(File.exist?(File.join(root, "reviews"))).to be(false)
      document[:snapshot].delete(:target)
      File.write(path, JSON.generate(document))
      expect(Wireless::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: StringIO.new)).to eq(2)
      expect(File.exist?(File.join(root, "reviews"))).to be(false)
      document[:snapshot][:target] = { host: "192.0.2.1" }
      File.write(path, JSON.generate(document))
      File.write(File.join(root, "devices", "duplicate.json"), JSON.generate(document))
      expect(Wireless::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: StringIO.new)).to eq(2)
      expect(File.exist?(File.join(root, "reviews"))).to be(false)
    end
  end

  it "does not export executable plans from partial or ambiguous configuration even with supplied advice" do
    observation = Wireless::Config.new.parse("wlan service-template A\n cipher-suite tkip ccmp\n security-ie wpa rsn\n service-template enable\nreturn\n", complete: true)
    expect(observation).to be_complete
    document = JSON.parse(JSON.generate(schema_version: 3, kind: "collection", device: { name: "AC", host: "192.0.2.1", platform: "h3c_wireless" },
      snapshot: { collection_status: "complete", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1" }, observations: { configuration: observation.to_h } }))
    advice = Wireless::Recommendations.new(document).call
    expect(advice[:items]).to include(include(status: "candidate"))
    [ [ "partial", observation.records ], [ "complete", observation.records * 2 ] ].each_with_index do |(status, records), index|
      Dir.mktmpdir do |root|
        report = Wireless::CLI::Report.new(File.join(root, "reports"), scripts: true)
        document["snapshot"]["observations"]["configuration"].merge!("status" => status, "records" => JSON.parse(JSON.generate(records)))
        entry = report.write_review(document, basename: "case#{index}", source: "input", source_sha256: "a" * 64, advice: advice)
        report.finish_review([ entry ], source_batch: root)
        expect(JSON.parse(File.read(File.join(report.directory, "plan.json"))).fetch("changes")).to be_empty
      end
    end
  end

  it "binds every template plan to its device configuration and refreshes the fingerprint on the next report" do
    Dir.mktmpdir do |root|
      report = Wireless::CLI::Report.new(File.join(root, "reports"), scripts: true)
      text = %w[A B].map do |name|
        "wlan service-template #{name}\n ssid #{name}\n cipher-suite tkip ccmp\n security-ie wpa rsn\n service-template enable\n#\n"
      end.join("") + "return\n"
      observation = Wireless::Config.new.parse(text, complete: true)
      expect(observation).to be_complete
      document = JSON.parse(JSON.generate(schema_version: 3, kind: "collection", device: { name: "AC", host: "192.0.2.1", platform: "h3c_wireless" },
        snapshot: { collection_status: "complete", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1" }, observations: { configuration: observation.to_h } }))
      original = CtxRunner::Fingerprint.call(document.dig("snapshot", "observations", "configuration", "records", 0))
      first = report.write_review(document, basename: "first", source: "input", source_sha256: "a" * 64)
      document["snapshot"]["observations"]["configuration"]["records"][0]["service_templates"][0]["ssid"] = "changed"
      current = CtxRunner::Fingerprint.call(document.dig("snapshot", "observations", "configuration", "records", 0))
      second = report.write_review(document, basename: "second", source: "input", source_sha256: "b" * 64)

      report.finish_review([ first, second ], source_batch: root)
      path = File.join(report.directory, "plan.json")
      expect(File.read("#{path}.sha256").strip).to eq(Digest::SHA256.file(path).hexdigest)
      changes = JSON.parse(File.read(path)).fetch("changes")
      expect(current).not_to eq(original)
      { "first" => original, "second" => current }.each do |basename, digest|
        plans = changes.select { |id, _| id.start_with?("#{basename}--") }.values
        expect(plans.size).to eq(2)
        expect(plans.map { |plan| plan["change"]["name"] }).to eq(%w[A B])
        expect(plans.map { |plan| plan["expected_config_sha256"] }).to eq([ digest, digest ])
        expect(plans).to all(include("commands" => include(" undo cipher-suite tkip"), "rollback" => include(" cipher-suite tkip")))
      end
    end
  end

  it "accepts the actual parser configuration schema including the AP map" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "devices"))
      observation = Wireless::Config.new.parse("wlan ap ap1 model WA6530\n radio 1\n  service-template missing vlan 10\n#\n", complete: true)
      File.write(File.join(root, "devices", "ac.json"), JSON.generate(schema_version: 3, kind: "collection", device: { name: "AC", host: "192.0.2.1", platform: "h3c_wireless" }, snapshot: { collection_status: "complete", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1" }, observations: { configuration: observation.to_h } }))
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
      body = JSON.generate(schema_version: 3, kind: "collection", device: { name: "LEAF", host: "192.0.2.1", platform: "h3c_wireless" }, snapshot: { collection_status: "partial", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1" }, observations: { configuration: { name: "configuration", status: "partial", records: [], issues: [] } } })
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

  it "preserves every device when collection reports finish concurrently" do
    Dir.mktmpdir do |root|
      report = Wireless::CLI::Report.new(File.join(root, "out"))
      ready, start = Queue.new, Queue.new
      hosts = (1..8).map { |index| "192.0.2.#{index}" }
      workers = hosts.reverse.map do |host|
        Thread.new do
          ready << true
          start.pop
          report.write({ device: { "name" => "WLC", "host" => host, "platform" => "h3c_wireless" }, status: :failed, dimensions: {} })
        end
      end
      workers.size.times { ready.pop }
      workers.size.times { start << true }
      workers.each(&:value)
      report.finish_collected_review

      summary = JSON.parse(File.read(File.join(report.directory, "review.json")))
      expect(summary).to include("status" => "complete", "devices" => hosts.size)
      expect(summary.fetch("reports").map { |entry| entry.fetch("device").fetch("host") }).to eq(hosts)
      expect(Dir[File.join(report.directory, "devices", "*.json")].size).to eq(hosts.size)
      plan = File.join(report.directory, "plan.json")
      expect(File.read("#{plan}.sha256").strip).to eq(Digest::SHA256.file(plan).hexdigest)
      expect(JSON.parse(File.read(plan))).to include("schema_version" => 3, "kind" => "change_plan")
    end
  end

  it "finishes advice publication when another worker creates the recommendation directory first" do
    Dir.mktmpdir do |root|
      report = Wireless::CLI::Report.new(File.join(root, "out"))
      folder = File.join(report.directory, "recommendations")
      allow(File).to receive(:open).and_call_original
      expect(File).to receive(:open).with(report.directory, File::RDONLY | File::NOFOLLOW).at_least(:once).and_call_original
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
      File.write(File.join(root, "devices", "bad.json"), JSON.generate(schema_version: 3, kind: "collection", device: { name: "test", host: "192.0.2.1" }, snapshot: { collection_status: "partial", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1" }, observations: { configuration: { name: "configuration", status: "partial", records: [], issues: "private-password" } } }))
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
      document = { "schema_version" => 3, "kind" => "collection", "device" => { "host" => "192.0.2.1", "name" => "test" }, "snapshot" => nil }
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
