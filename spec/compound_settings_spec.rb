# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Wireless compound configuration settings" do
  let(:parser) { Wireless::Configuration.new }

  def radio(text)
    result = parser.parse("wlan ap AP model TEST\n radio 1\n#{text}return\n", complete: true)
    [ result, result.records.first.dig(:access_points, "AP", :radios, "1") ]
  end

  it "validates a complete channel setting before recording any of its fields" do
    result, settings = radio("  channel nonsense\n")
    expect(result).to be_partial
    expect(settings).not_to have_key(:channel)
    expect(settings).not_to have_key(:channel_number)
    result, settings = radio("  channel 36\n  channel nonsense\n")
    expect(result).to be_partial
    expect(settings).to include(channel: "36", channel_number: 36)
    expect(result.issues).not_to include(include(code: :conflicting_configuration_value))
  end

  it "does not retain automatic-channel flags after conflicting fixed channel declarations" do
    [ [ "channel auto unlock", "channel 36", "channel auto unlock" ],
      [ "channel 36", "channel auto unlock", "channel 36" ] ].each do |commands|
      result, settings = radio(commands.map { |command| "  #{command}\n" }.join)
      expect(result).to be_partial
      %i[channel channel_number channel_unlocked].each { |field| expect(settings).not_to have_key(field) }
    end
  end

  it "keeps password-presence metadata consistent with ambiguous MAC username formats" do
    source = "wlan service-template LAB\n mac-authentication user-name-format fixed password simple PRIVATE\n" \
      " mac-authentication user-name-format mac-address\n mac-authentication user-name-format fixed password simple PRIVATE\nreturn\n"
    result = parser.parse(source, complete: true)
    expect(result).to be_partial
    settings = result.records.first[:service_templates].first[:configuration]
    expect(settings).not_to have_key(:mac_authentication_user_name_format)
    expect(settings).not_to have_key(:mac_authentication_has_password)
    expect(result.to_h.inspect).not_to include("PRIVATE")
  end
end
