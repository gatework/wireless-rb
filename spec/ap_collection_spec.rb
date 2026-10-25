# frozen_string_literal: true

require_relative "spec_helper"
require "wireless/ap_collection"

RSpec.describe Wireless::ApCollection do
  let(:now) { Time.utc(2026, 10, 25) }
  let(:session) { Object.new }
  let(:access_points) do
    Wireless::Observation.new(name: :access_points, status: :complete,
      records: [ { name: "AP-1", model: nil }, { name: "AP-2", model: nil } ])
  end

  it "keeps AP selection independent of clock and credential callbacks" do
    names = [ +"AP-1" ]
    capture = CtxDriver::Capture.new(command: Wireless::H3c::Profile::COMMANDS.fetch(:lldp),
      body: "No LLDP neighbors\n", started_at: now, completed_at: now)
    reader = double("AP reader")
    expect(reader).to receive(:read).with(access_point: include(name: "AP-1")).once.and_return(result: capture)
    factory = ->(controller:) { expect(controller).to equal(session); reader }
    clock = -> { names.first.replace("AP-2"); now }
    collection = described_class.new(clock: clock, ap_session_factory: factory)

    result = collection.collect(session: session, access_points: access_points, names: names)

    expect(result.evidence).to contain_exactly(include(ap_name: "AP-1", status: :complete))
    expect(names).to eq([ "AP-2" ])
  end

  it "does not access credentials or create a reader when selection matches no AP" do
    factory, credentials = double("AP factory"), double("AP credentials")
    expect(factory).not_to receive(:call)
    expect(credentials).not_to receive(:call)
    collection = described_class.new(clock: -> { now }, ap_session_factory: factory)

    result = collection.collect(session: session, access_points: access_points,
      credentials: credentials, names: [ "MISSING" ])

    expect(result.status).to eq(:failed)
    expect(result.issues).to include(code: :ap_not_found, ap_name: "MISSING")
    expect(result.evidence).to be_empty
  end

  it "rejects invalid requests before resolving credentials" do
    credentials = double("AP credentials")
    expect(credentials).not_to receive(:call)
    collection = described_class.new
    expect do
      collection.collect(session: session, access_points: access_points, credentials: credentials, names: [ "AP\n1" ])
    end.to raise_error(ArgumentError)
    expect do
      collection.collect(session: session, access_points: Wireless::Observation.new(name: :clients, status: :complete),
        credentials: credentials)
    end.to raise_error(ArgumentError)
  end
end
