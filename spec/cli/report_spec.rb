# frozen_string_literal: true

require_relative "../spec_helper"
require "wireless/cli/report"
require "tmpdir"

RSpec.describe Wireless::CLI::Report do
  around do |example|
    Dir.mktmpdir do |directory|
      @root = File.join(directory, "reports")
      example.run
    end
  end

  let(:result) { { device: { "host" => "192.0.2.10", "name" => "WLC" }, status: :complete, dimensions: {} } }

  it "retains a safe checkpoint when final replacement never committed and storage stays full" do
    report = described_class.new(@root)
    original = File.method(:rename)
    attempts = 0
    allow(File).to receive(:rename) do |source, target|
      attempts += 1 if target.end_with?("/summary.json")
      raise Errno::ENOSPC if target.end_with?("/summary.json") && attempts >= 2
      original.call(source, target)
    end
    expect { report.finish([ result.merge(report_saved: true) ]) }.to raise_error(described_class::Error)
    expect(File).to exist(File.join(report.directory, "summary.json"))
    saved = JSON.parse(File.read(File.join(report.directory, "summary.json")))
    expect(saved).to include("status" => "incomplete", "completed" => 1)
  end

  it "invalidates an older successful summary when a cancelled finish cannot publish its checkpoint" do
    report = described_class.new(@root)
    report.finish([ result.merge(report_saved: true) ])
    original = File.method(:rename)
    allow(File).to receive(:rename) do |source, target|
      raise Errno::ENOSPC if target.end_with?("/summary.json")
      original.call(source, target)
    end
    expect { report.finish([ result.merge(report_saved: true) ], interrupted: true) }.to raise_error(described_class::Error)
    expect(File).not_to exist(File.join(report.directory, "summary.json"))
  end

  it "preserves the original cancellation after final rename even when checkpoint recovery fails" do
    report = described_class.new(@root)
    original = File.method(:rename)
    cancellation = Interrupt.new("first cancellation")
    attempts = 0
    allow(File).to receive(:rename) do |source, target|
      attempts += 1 if target.end_with?("/summary.json")
      raise Errno::ENOSPC if target.end_with?("/summary.json") && attempts >= 3
      original.call(source, target)
      raise cancellation if target.end_with?("/summary.json") && attempts == 2
    end
    expect { report.finish([ result.merge(report_saved: true) ]) }.to raise_error { |error| expect(error).to equal(cancellation) }
    expect(report).to be_recovery_failed
    expect(File).not_to exist(File.join(report.directory, "summary.json"))
  end

  it "leaves an explicitly incomplete JSON checkpoint when text summary publication fails" do
    report = described_class.new(@root)
    original = File.method(:rename)
    allow(File).to receive(:rename) do |source, target|
      raise Errno::ENOSPC, "private-summary-detail" if target.end_with?("/summary.txt")
      original.call(source, target)
    end
    expect { report.finish([ result.merge(report_saved: true) ], requested: [ result.fetch(:device) ]) }.to raise_error(described_class::Error)
    expect(File).to exist(File.join(report.directory, "summary.json"))
    saved = JSON.parse(File.read(File.join(report.directory, "summary.json")))
    expect(saved).to include("status" => "incomplete", "completed" => 1, "report_error" => "report_finalization_unconfirmed")
    expect(saved.fetch("devices").first).to include("status" => "complete", "report_saved" => true)
  end

  [ :rename, :directory_sync ].each do |phase|
    it "restores the incomplete checkpoint after final JSON #{phase} fails, retaining the original error" do
      report = described_class.new(@root)
      original = File.method(:rename)
      json_renames = 0
      allow(File).to receive(:rename) do |source, target|
        json_renames += 1 if target.end_with?("/summary.json")
        if json_renames == 2 && target.end_with?("/summary.json")
          raise Errno::ENOSPC if phase == :rename
        end
        original.call(source, target)
      end
      original_open = File.method(:open)
      allow(File).to receive(:open) do |*args, **kwargs, &operation|
        next original_open.call(*args, **kwargs) unless operation
        original_open.call(*args, **kwargs) do |file|
          if phase == :directory_sync && json_renames == 2 && file.stat.directory?
            allow(file).to receive(:fsync).and_raise(Errno::EIO)
          end
          operation.call(file)
        end
      end
      expect { report.finish([ result.merge(report_saved: true) ]) }.to raise_error(described_class::Error) { |error|
        expect(error.phase).to eq(phase)
      }
      expect(File).to exist(File.join(report.directory, "summary.json"))
      saved = JSON.parse(File.read(File.join(report.directory, "summary.json")))
      expect(saved).to include("status" => "incomplete", "report_error" => "report_finalization_unconfirmed")
      expect(File.read(File.join(report.directory, "summary.txt"))).to include("summary.json")
    end
  end

  it "retains interrupted status in the checkpoint when summary publication fails" do
    report = described_class.new(@root)
    original = File.method(:rename)
    allow(File).to receive(:rename) do |source, target|
      raise Errno::ENOSPC if target.end_with?("/summary.txt")
      original.call(source, target)
    end
    expect { report.finish([], interrupted: true) }.to raise_error(described_class::Error)
    expect(File).to exist(File.join(report.directory, "summary.json"))
    expect(JSON.parse(File.read(File.join(report.directory, "summary.json")))).to include("status" => "interrupted")
  end

  it "rejects a preexisting root accessible by other users" do
    Dir.mkdir(@root, 0o755)
    expect { described_class.new(@root) }.to raise_error(ArgumentError, /0700/)
    expect(Dir.children(@root)).to be_empty
    expect(File.stat(@root).mode & 0o777).to eq(0o755)
  end

  it "rejects a symlink root without writing through it" do
    target = "#{@root}-target"
    Dir.mkdir(target, 0o700)
    File.symlink(target, @root)
    expect { described_class.new(@root) }.to raise_error(ArgumentError, /0700/)
    expect(Dir.children(target)).to be_empty
  end

  it "retains committed JSON and safe publication details when device text cannot be renamed" do
    report = described_class.new(@root)
    original = File.method(:rename)
    allow(File).to receive(:rename) do |source, target|
      raise Errno::ENOSPC, "private-file-detail" if target.end_with?(".txt")
      original.call(source, target)
    end
    expect { report.write(result) }.to raise_error(IOError) { |error|
      expect(error.class.name).to eq("Wireless::CLI::Report::Error")
      expect(error.relative).to eq("devices/WLC-192.0.2.10.txt")
      expect(error.phase).to eq(:rename)
      expect(error).not_to be_committed
      expect(error.message + error.inspect).not_to include("private-file-detail")
    }
    expect(File).to exist("#{report.directory}/devices/WLC-192.0.2.10.json")
    expect(Dir["#{report.directory}/devices/.*.tmp"]).to be_empty
  end

  it "distinguishes committed output from confirmed directory durability" do
    report = described_class.new(@root)
    original = File.method(:open)
    allow(File).to receive(:open) do |*args, **kwargs, &operation|
      next original.call(*args, **kwargs) unless operation
      original.call(*args, **kwargs) do |file|
        allow(file).to receive(:fsync).and_raise(Errno::EINVAL, "private-sync-detail") if file.stat.directory?
        operation.call(file)
      end
    end
    expect { report.write(result) }.to raise_error(IOError) { |error|
      expect(error.class.name).to eq("Wireless::CLI::Report::Error")
      expect(error.phase).to eq(:directory_sync)
      expect(error).to be_committed
      expect(error.message).not_to include("private-sync-detail")
    }
    expect(File).to exist("#{report.directory}/devices/WLC-192.0.2.10.json")
  end

  it "syncs each published file and its containing directory with private permissions" do
    report = described_class.new(@root)
    synced = []
    original = File.method(:open)
    allow(File).to receive(:open) do |*args, **kwargs, &operation|
      next original.call(*args, **kwargs) unless operation
      original.call(*args, **kwargs) do |file|
        allow(file).to receive(:fsync).and_wrap_original do |sync|
          synced << file.path if file.stat.directory?
          sync.call
        end
        operation.call(file)
      end
    end
    report.write(result)
    report.finish([ result ], requested: [ result.fetch(:device) ])
    expect(synced).to eq([ "#{report.directory}/devices" ] * 2 + [ "#{report.directory}/recommendations" ] * 3 + [ report.directory ] * 3)
    Dir["#{report.directory}/**/*"].each do |path|
      expect(File.stat(path).mode & 0o777).to eq(File.directory?(path) ? 0o700 : 0o600)
    end
  end

  it "does not report complete when requested targets have never been collected" do
    report = described_class.new(@root)
    missing = { "host" => "192.0.2.11", "name" => "SPARE" }
    summary = report.finish([ result ], requested: [ result.fetch(:device), missing ])
    expect(summary[:status]).to eq(:incomplete)
    expect(summary[:pending]).to eq([ missing ])
  end
end
