# wireless-rb

[简体中文](README-zh.md) | [Source](https://github.com/gatework/wireless-rb) | [Changelog](CHANGELOG.md)

Wireless controller configuration and runtime observations in pure Ruby. Vendor command parsers model access points, radios, clients, and service configuration while keeping observations separate from inventory persistence.

## Command line

Install the `wireless-rb` gem to use `wireless collect` and `wireless parse`, or run the source entry point:

```sh
ruby bin/wireless.rb --help-all
ruby bin/wireless.rb --plan
ruby bin/wireless.rb
ruby bin/wireless collect --help-all
ruby bin/wireless collect --init --non-interactive
ruby bin/wireless collect --plan
ruby bin/wireless parse --dimension access_points --file aps.txt --complete
```

The CLI follows VXLAN conventions for layered configuration, inventory filtering, concurrency, progress, private per-device reports and exit codes. Collection supports H3C and Huawei; AP LLDP is explicit and uses separate AP credentials. Host configuration and collection require optional `net-connector >= 0.18.0` with `Config`; environment-file parsing is provided by that dependency. Parser installation stays independent of transport. Both `wireless collect` and `ruby bin/wireless.rb` discover system, user, script-directory and invocation-directory files, then overlay explicit files. Values follow CLI > process environment > YAML > .env > defaults. Initialization writes to the user configuration directory or explicit paths; reports default to `wireless-reports/` in the invocation directory. See the [CLI guide](bin/README.md).


## Features

- H3C configuration, access points, radios, BSSs, clients, groups, service templates, and authentication observations.
- Limited Huawei AP/client runtime formats; unsupported dimensions remain explicit.
- Shared command parsing with independent completeness for each resulting view.
- Optional AP neighbor collection through the included net-connector AP-session adapter.

`Collector` coordinates controller queries and their dependencies. `ApCollection` handles AP selection, lazy credential resolution, LLDP receipt validation and coverage aggregation; `ApSession` owns the nested transport operation. The existing `Collector#collect` API is unchanged. For independent enrichment, require `wireless/ap_collection` and call `collect(session:, access_points:, credentials: nil, names: [])` with an immutable `Wireless::Observation` named `:access_points` and an explicit `ap_session_factory`. No matching AP means no credential callback or AP login. Each failed AP retains its evidence without discarding other AP results.

## Installation

Requires **Ruby 4.0.6 or newer**. Add this line to your application's `Gemfile`:

```ruby
gem "wireless-rb", require: "wireless"
```

Then run `bundle install`, or install directly with `gem install wireless-rb`. The require path is `wireless` and the public namespace is `Wireless`; package names and Ruby namespaces are intentionally separate.

Runtime dependencies include [`ctx_parser`](https://github.com/gatework/ctx_parser), [`ctx_driver`](https://github.com/gatework/ctx_driver), [`ctx_runner`](https://github.com/gatework/ctx_runner) and [`ctx_cli`](https://github.com/gatework/ctx_cli), without version constraints in the gemspec. Offline parsing and injected controller collection do not install or load `net-connector`. Applications should commit their own `Gemfile.lock` to make deployments reproducible. No Rails boot or sibling checkout paths are required.

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
observations = Wireless::RuntimeParser.new(platform: :h3c).parse_many(
  %i[access_points radios], output, complete: true
)
observations.each do |name, observation|
  puts "#{name}: #{observation.status}, records=#{observation.records.size}"
end
# 两个视图共用一次解析，各自保留完整性状态。
```

## Public contract and limits

`Config.new.parse(text, complete: false)` parses controller configuration. `RuntimeParser.new(platform: :h3c, model: nil).parse(name, text, complete: false, command: nil)` parses one runtime dimension; `parse_many` shares parsing for dimensions from the same command. `NeighborParser` supplies the AP context to neighbor observations.

Invalid platform/model/dimension arguments and non-boolean `complete` raise `ArgumentError`; malformed device text produces a failed observation. The caller must establish input completeness. Unknown syntax, duplicate identities, count mismatches, and truncated output remain partial or failed. A configured maximum transmit power is not a current measured transmit power. PSKs, passwords, and authentication URLs must not enter snapshots.

`NeighborParser#parse` also rejects invalid AP names and non-text input with `ArgumentError`; unsupported platform dimensions remain `unsupported`. `Observation` timestamps accept `Time` or `nil`, including replacements through `with`.

Conflicting runtime fields and singleton settings within one configuration block are excluded and keep their source evidence incomplete; later declarations in that block cannot restore the ambiguous value. Separate sequential configuration blocks retain their own source captures. Unknown nested wireless declarations cannot certify an empty configuration. Observation names must be symbols; display strings, including `PP.pp` for observations, snapshots and projections, contain metadata only. An empty coverage scope is unknown, and freshness windows must be finite and nonnegative.

Radio channel, bandwidth, transmit-power and enable/disable settings, plus template PSK, AKM, cipher and security-IE settings, must belong to their corresponding configuration views. A misplaced command remains unsupported source evidence and cannot create a fact in its enclosing object; see the [H3C command views](https://www.h3c.com/en/d_202004/1286221_294551_0.htm).

Omitting `dimensions` selects the platform profile’s controller commands; AP LLDP remains explicit. Explicitly selected unsupported dimensions retain `unsupported`. `Collector#collect(connector:, target:, platform:, model: nil, dimensions: nil, ap_credentials: nil, ap_names: [])` uses a host-supplied connector; ordinary collection only requires `connected?` and `send_commands` on its sessions. For AP LLDP, inject `Collector.new(ap_session_factory: factory)`. The factory receives `controller:` plus lazily resolved `ap_credentials` keywords and returns an object with `read(access_point:)`. When APs need querying but no factory was supplied, only LLDP reports `ap_session_required`; credentials are not read and controller observations remain available.

The collector fixes its platform/model profile before opening the connection and parses each shared query once. It accepts one session callback per collection; repeated callbacks do not replay controller or AP queries, retain the first observations, and mark collection failure as `session_reentered`.

The included AP login adapter is optional. Declare `gem "net-connector", ">= 0.13.0", require: false` in the host application, use `ctx_driver >= 0.2.2`, then load and inject it explicitly:

```ruby
require "wireless"
require "wireless/ap_session"

collector = Wireless::Collector.new(
  ap_session_factory: ->(controller:, **credentials) { Wireless::ApSession.new(controller: controller, **credentials) }
)
```

This adapter requires an AP password and optional username through `ap_credentials`; custom adapters can own their credentials. `read` returns a hash containing `result: CtxDriver::Capture`, optional `error:` / `cleanup_error:` / `close_error:` symbol codes (or `nil`), and an optional boolean `skipped:`. Malformed outcomes produce `invalid_command_result`; non-symbol error codes are normalized to that code while preserving any valid captured neighbors. The host or adapter owns credentials and session lifecycle; parsers never infer AP console activation or credentials.

AP access reuses the connected controller and its operation lease; it does not open a separate AP transport. Login, read-only queries, confirmed return, and any failure close share that lease. A busy controller is left untouched. The adapter sends `quit` only from the confirmed AP prompt, and preserves cancellation and independent cleanup failures. Empty AP inventories do not resolve credentials or construct adapters.

Detailed vendor behavior, historical validation notes, and Motor-only integration are preserved in [the architecture reference](docs/architecture-zh.md). Host integration examples in that reference require Motor; they are not standalone gem APIs. Motor adapters live under `backend/lib/baseline`, `backend/lib/vxlan`, and `backend/lib/wireless` in the [Motor repository](https://github.com/gatework/motor/tree/main/backend/lib).

The lifecycle connector is a host adapter exposing `open { |session| }` (and `platform` for VXLAN and Wireless). It is distinct from a native `Net::Connector::Base` device instance. Borrowed native sessions are accepted by `CtxDriver::Reader` and `CtxChecker::Collector#collect_session`; they are never implicitly connected or retried.

## Domain vocabulary

H3C BSS/client records retain `VLAN ID` as `vlan` and `Service VLAN ID` as `service_vlan`, including an explicit unknown service VLAN. Client `SM power save` remains `power_save`; `SM power save mode` is `power_save_mode`. These are distinct device fields, not aliases; the former alias behavior is corrected. See [H3C output examples](https://www.h3c.com/cn/d_202206/1627690_30005_0.htm). Repeated `cipher-suite` and `security-ie` configuration lines accumulate their enabled members, as shown in [H3C mixed-security configuration](https://knowledge.h3c.com/Theme/details/137418).

H3C command parsers share `H3c::Parser` for command-output validation and `H3c::RecordParser` for labeled records. `H3c::AuthenticationFields` supplies shared authentication fields; `H3c::Document` preserves configuration source lines. Huawei uses `Huawei::Profile` and command parsers under `Huawei::Parsers`, with the same parameter contract.

APs, radios, BSSs, and associated clients have distinct identities. H3C `Online time` is `online_seconds`; AP `System uptime` is `uptime_seconds`, as shown by the [distinct device fields](https://www.h3c.com/cn/d_202606/2850182_30005_0.htm). Explicit authentication modes take precedence over configured domain references, and combined or fallback modes retain their order instead of becoming a single authentication method; see the [H3C authentication reference](https://www.h3c.com/en/d_202106/1418918_294551_0.htm). Opaque LLDP chassis IDs preserve case, while an explicit MAC subtype is normalized. Measurement conversion names expose output units: `Fields.duration_seconds`, `Fields.rates_mbps`, and `Fields.channel_width_mhz`. `Fields.frequency_band` requires an unambiguous frequency-band label or band-specific PHY evidence. A channel number alone, or a generic `802.11ax` label, does not establish a band; channel numbers are not accepted as band evidence. See the [Cisco 6-GHz channel examples](https://www.cisco.com/c/en/us/support/docs/wireless/catalyst-9166-series-access-points/220526-configure-and-verify-wi-fi-6e-band-opera.html).

Radio capability details preserve their subsection: `details[:vht_mcs]`, `[:ht_mcs]`, `[:he_mcs]`, and `[:operational_rates]` each own labels such as `supported` and `mandatory`. AP totals establish AP coverage; an AP without reported Radio evidence leaves the Radio view incomplete, while the AP view can remain complete. AP LLDP adapters must return a capture for the requested LLDP command; the collector owns AP identity and attempted-status metadata.

`authentication_type` summarizes recognized authentication configuration. Combined deployment layers such as PSK and Portal remain in `configuration[:akm_modes]` and `configuration[:portal]`; a baseline checking all enabled mechanisms must inspect those fields.

## Development and tests

Name shared classes by their responsibility and use the namespace for platform context. Preserve filenames and class names that directly match device commands.

```sh
bundle install
bundle exec rake
bundle exec ruby examples/offline.rb
bundle exec rake build
```

`bundle exec rake` runs RSpec, RuboCop, and the offline examples. Tests live in `spec/`, following the existing project's RSpec convention; fixtures use synthetic or sanitized evidence. Add regression cases for successful, incomplete, unsupported, and malformed inputs when extending a parser. Offline tests do not certify all device versions or replace live integration checks.

Run `bundle exec ruby -Ilib benchmark/tables.rb` for synthetic 500, 2,000, and 5,000-entry template, binding, and LLDP continuation cases, plus 100,000-line terminal full-scan and first-error cases. Each case validates its result and reports the fastest of three local samples plus object allocations; it does not measure device or network performance.

Use the declared minimum Ruby version for compatibility checks. Document source methods and non-obvious business logic in concise Chinese, preserve public return/error contracts, and never add raw device captures or credentials to examples, fixtures, logs, or release archives.

## Release

This directory can be maintained as the independent [wireless-rb](https://github.com/gatework/wireless-rb) repository. Update `VERSION` and `CHANGELOG.md`, run the validation and build commands above, and inspect the packaged file list before tagging `vVERSION`.

CI runs tests, lint, examples, build, and an isolated installation on Linux and macOS. After CI passes on `main`, push `vVERSION` to run the release workflow. It publishes the tested Linux artifact to RubyGems and GitHub Releases, attaches `SHA256SUMS`, and verifies downloaded bytes. The GitHub `release` environment accepts a `RUBYGEMS_API_KEY` secret; without it, configure RubyGems Trusted Publishing for this repository, `release.yml`, and the `release` environment. Retry a failed publish job to reuse its CI artifact; an already published version must have identical bytes. See [release details](docs/release.md).

Publish dependency gems first. A Git tag, a successful build, or a workflow file does not establish that the gem has reached RubyGems; confirm the registry result separately. See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

MIT. See [LICENSE](LICENSE).

## Remediation recommendations

`wireless collect` 默认输出逐设备诊断，使用 `--scripts` 可选导出配置建议；`wireless review --batch DIR` 可离线补生成既有报告的候选配置、条件回退和只读验收命令。导出不会执行变更；独立 `apply --plan FILE --item ID` 必须在真实终端明确确认，配置漂移或失败即停止。详见[修复建议说明](docs/remediation.md)。

Apply returns `2` on failure and `130` on interruption even if stderr cannot accept diagnostics. Existing execution journals retain uncertain device effects; commands are never replayed automatically. Unexpected positional arguments are rejected, including after `--help`.

Offline review requires `snapshot.target.host` to match the canonical device host. Reports without target identity must be collected again; the unbound legacy format is no longer accepted.


## API migration

`RuntimeParser.new(platform:, model: nil)` fixes the platform for `parse(name, text, complete: false, command: nil)` and `parse_many(names, text, complete: false, command: nil)`. Snapshots use `observations:` and expose `observations` / `observation(name)`; the old Ruby `dimensions` member and Wireless `dimension` accessor are removed. Known missing dimensions return `not_requested`; unknown names raise `ArgumentError`. Persisted schema 3 JSON uses `observations` and an independent `collection_status`; regenerate older reports.

`Collector#collect_session(session:, target:, platform:, ...)` runs the same collection plan using an already connected session without connecting or closing it. AP LLDP still requires an explicitly injected factory.

Dynamic inventory uses `Netdisco::Catalog`. Any duplicate row for a selected address, including another platform, prevents connection; excluded conflicts retain safe diagnostics. `NC_<PLATFORM>_ENABLE_PASSWORD` takes precedence over `NC_ENABLE_PASSWORD`.

本次契约升级要求重新生成旧报告和计划；Ruby 快照使用 `observations`、`collection_status` 和 `Time`，JSON 通过 `CtxRunner::Document` 输出 UTC ISO8601（解析基础库仅提供 `Result`）。跨模块约定见 [ctx_runner 契约迁移](https://github.com/gatework/ctx_runner/blob/main/docs/contracts-2026-10-29.md)。
