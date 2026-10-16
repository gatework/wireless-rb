# wireless-rb

[简体中文](README-zh.md) | [Source](https://github.com/gatework/wireless-rb) | [Changelog](CHANGELOG.md)

Wireless controller configuration and runtime observations in pure Ruby. Vendor command parsers model access points, radios, clients, and service configuration while keeping observations separate from inventory persistence.

## Features

- H3C configuration, access points, radios, BSSs, clients, groups, service templates, and authentication observations.
- Limited Huawei AP/client runtime formats; unsupported dimensions remain explicit.
- Shared command parsing with independent completeness for each resulting view.
- Optional AP neighbor collection through the included net-connector AP-session adapter.

## Installation

Requires **Ruby 4.0.6 or newer**. Add this line to your application's `Gemfile`:

```ruby
gem "wireless-rb", require: "wireless"
```

Then run `bundle install`, or install directly with `gem install wireless-rb`. The require path is `wireless` and the public namespace is `Wireless`; package names and Ruby namespaces are intentionally separate.

Internal runtime dependencies: [`ctx_parser`](https://github.com/gatework/ctx_parser), [`ctx_driver`](https://github.com/gatework/ctx_driver), [`net-connector`](https://github.com/gatework/net-connector). The gemspec declares runtime dependencies without version constraints. Applications should commit their own `Gemfile.lock` to make deployments reproducible. No Rails boot or sibling checkout paths are required.

Release artifacts and checksums are available from [GitHub Releases](https://github.com/gatework/wireless-rb/releases). Check [RubyGems](https://rubygems.org/gems/wireless-rb) for published versions.

## Offline example

From a development checkout after installing dependencies:

```sh
bundle exec ruby examples/offline.rb
```

The example uses synthetic data and performs no network access:

```ruby
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
```

## Public contract and limits

`Configuration.new.parse(text, complete: false)` parses controller configuration. `RuntimeParser.new(model: nil).parse(name, text, platform: "h3c", complete: false)` parses one runtime dimension; `parse_many` shares parsing for dimensions from the same command. `NeighborParser` supplies the AP context to neighbor observations.

The caller must establish input completeness. Unknown syntax, duplicate identities, count mismatches, and truncated output remain partial or failed. A configured maximum transmit power is not a current measured transmit power. PSKs, passwords, and authentication URLs must not enter snapshots.

`Collector#collect(connector:, target:, platform:, model: nil, dimensions:, ap_connection: nil, ap_names: [])` uses an injected connector. `net-connector` is an explicit runtime dependency for the included `ApSession`; an LLDP request needs explicit AP credentials through `ap_connection`. The host owns device identity and connection settings. AP console activation and AP credentials are never inferred by the parser. Rails inventory projection, locking, encryption, APIs, and `Wireless::Sync` belong to the host and are not shipped in this gem.

Detailed vendor behavior, historical validation notes, and Motor-only integration are preserved in [the architecture reference](docs/architecture-zh.md). Host integration examples in that reference require Motor; they are not standalone gem APIs. Motor adapters live under `backend/lib/baseline`, `backend/lib/vxlan`, and `backend/lib/wireless` in the [Motor repository](https://github.com/gatework/motor/tree/main/backend/lib).

The lifecycle connector is a host adapter exposing `open { |session| }` (and `platform` for VXLAN and Wireless). It is distinct from a native `Net::Connector::Base` device instance. Borrowed native sessions are accepted by `CtxDriver::Reader` and `CtxChecker::Collector#collect_session`; they are never implicitly connected or retried.

## Development and tests

```sh
bundle install
bundle exec rake
bundle exec ruby examples/offline.rb
bundle exec rake build
```

`bundle exec rake` runs RSpec, RuboCop, and the offline examples. Tests live in `spec/`, following the existing project's RSpec convention; fixtures use synthetic or sanitized evidence. Add regression cases for successful, incomplete, unsupported, and malformed inputs when extending a parser. Offline tests do not certify all device versions or replace live integration checks.

Use the declared minimum Ruby version for compatibility checks. Document source methods and non-obvious business logic in concise Chinese, preserve public return/error contracts, and never add raw device captures or credentials to examples, fixtures, logs, or release archives.

## Release

This directory can be maintained as the independent [wireless-rb](https://github.com/gatework/wireless-rb) repository. Update `VERSION` and `CHANGELOG.md`, run the validation and build commands above, and inspect the packaged file list before tagging `vVERSION`.

CI runs tests, lint, examples, build, and an isolated installation on Linux and macOS. After CI passes on `main`, push `vVERSION` to run the release workflow. It publishes the tested Linux artifact to RubyGems and GitHub Releases, attaches `SHA256SUMS`, and verifies downloaded bytes. The GitHub `release` environment accepts a `RUBYGEMS_API_KEY` secret; without it, configure RubyGems Trusted Publishing for this repository, `release.yml`, and the `release` environment. Retry a failed publish job to reuse its CI artifact; an already published version must have identical bytes. See [release details](docs/release.md).

Publish dependency gems first. A Git tag, a successful build, or a workflow file does not establish that the gem has reached RubyGems; confirm the registry result separately. See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

MIT. See [LICENSE](LICENSE).
