# frozen_string_literal: true

require_relative "spec_helper"
require "pp"

RSpec.describe "Immutable facts and evidence" do
  [ Wireless::Observation ].each do |type|
    context type.name do
      let(:attributes) { type == CtxParser::Result ? {} : { name: :configuration } }

      it "detaches nested facts and diagnostics without freezing caller data" do
        records = [ { name: +"leaf", nested: { members: [ +"Ethernet1/1" ] } } ]
        issues = [ { code: :partial_source, fields: [ +"name" ] } ]
        value = type.new(**attributes, status: :partial, records: records, issues: issues)
        records.first[:name].replace("caller changed")
        records.first[:nested][:members].clear
        issues.first[:fields].clear

        expect(value.records).to eq([ { name: "leaf", nested: { members: [ "Ethernet1/1" ] } } ])
        expect(value.issues).to eq([ { code: :partial_source, fields: [ "name" ] } ])
        expect { value.records.first[:nested][:members].clear }.to raise_error(FrozenError)
        expect { value.issues.first[:fields].first.replace("changed") }.to raise_error(FrozenError)
      end

      it "keeps replacement facts independent while preserving Data value semantics" do
        original = type.new(**attributes, status: :complete, records: [ { name: "leaf" } ])
        input = [ { name: +"replacement" } ]
        replaced = original.with(status: :partial, records: input)
        input.first[:name].clear
        expect(replaced.records).to eq([ { name: "replacement" } ])
        expect(original.records).to eq([ { name: "leaf" } ])
        expect(replaced.to_h[:status]).to eq(:partial)
      end
    end
  end

  [ Wireless ].each do |domain|
    it "detaches #{domain} evidence and timestamps from caller state" do
      evidence = [ { command: +"show test", sha256: +"digest" } ]
      time = Time.now
            value = domain::Observation.new(name: :configuration, status: :complete,
        evidence: evidence, started_at: time, completed_at: time)
      evidence.first[:command].clear
      time.localtime("+09:00")

      expect(value.evidence.first[:command]).to eq("show test")
      expect(value.completed_at.utc_offset).to eq(0)
      expect { value.evidence.clear }.to raise_error(FrozenError)
      expect { value.completed_at.localtime("+07:00") }.to raise_error(FrozenError)
    end

    it "protects #{domain} snapshot identity and dimension coverage from caller mutation" do
      dimensions = { configuration: domain::Observation.new(name: :configuration, status: :complete) }
      target = { host: +"192.0.2.1", id: +"leaf-1" }
      attributes = {}
      value = domain::Snapshot.new(target: target, observations: dimensions, observed_at: Time.now, **attributes)
      dimensions.clear
      target[:host].replace("192.0.2.2")
      attributes[:fabric_key]&.clear

      expect(value).to be_complete
      expect(value.target[:host]).to eq("192.0.2.1")
      expect(value.fabric_key).to eq("LAB") if attributes.key?(:fabric_key)
      expect { value.observations.clear }.to raise_error(FrozenError)
      expect { value.target[:id].clear }.to raise_error(FrozenError)
      expect(value.observed_at).to be_frozen
    end
  end
  it "requires observation timestamps to be Time values or nil when constructing and replacing facts" do
    observation = Wireless::Observation.new(name: :clients, status: :complete)
    [ :started_at, :completed_at ].each do |field|
      [ "2026-10-18T00:00:00Z", [ +"caller-owned" ], {}, 1, false ].each do |invalid|
        expect do
          Wireless::Observation.new(name: :clients, status: :complete, **{ field => invalid })
        end.to raise_error(ArgumentError)
        expect { observation.with(**{ field => invalid }) }.to raise_error(ArgumentError)
      end
      time = Time.utc(2026, 10, 18)
      replaced = observation.with(**{ field => time })
      expect(replaced.public_send(field)).to eq(time)
      expect(replaced.public_send(field)).not_to equal(time)
      expect(replaced.public_send(field)).to be_frozen
      expect(replaced.with(**{ field => nil }).public_send(field)).to be_nil
    end
  end

  it "rejects mutable observation names" do
    expect { Wireless::Observation.new(name: +"clients", status: :complete) }.to raise_error(ArgumentError)
  end

  it "does not preserve caller hash defaults in snapshot dimensions" do
    [ Hash.new({ secret: +"PRIVATE_DEFAULT" }), Hash.new { raise "caller callback" } ].each do |dimensions|
      observation = Wireless::Observation.new(name: :clients, status: :complete)
      dimensions[:clients] = observation
      snapshot = Wireless::Snapshot.new(target: { host: "192.0.2.1" }, observations: dimensions)
      expect(snapshot.observations[:missing]).to be_nil
      expect(snapshot.observations[:clients]).to equal(observation)
    end
  end

  it "keeps fact, target and projection contents out of display strings" do
    observation = Wireless::Observation.new(name: :clients, status: :complete,
      records: [ { username: "PRIVATE_FACT" } ], evidence: [ { detail: "PRIVATE_EVIDENCE" } ])
    snapshot = Wireless::Snapshot.new(target: { host: "192.0.2.1", name: "PRIVATE_TARGET" }, observations: { clients: observation })
    projection = Wireless::Projection.new(dimensions: { clients: { status: :complete, detail: "PRIVATE_PROJECTION" } })
    [ observation, snapshot, projection ].each do |value|
      expect(value.inspect).not_to include("PRIVATE_")
      expect(value.to_s).to eq(value.inspect)
      expect("#{value}").not_to include("PRIVATE_")
      expect(PP.pp(value, +"").strip).to eq(value.inspect)
    end
  end
end
