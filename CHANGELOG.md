# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

## 0.2.0 (2026-10-17)

- Route Huawei commands through Profile and standard Parser contracts, and validate caller arguments before reading output. Keep malformed device bodies as failed observations.
- Share terminal rejection detection across platforms.

- Keep AP login, queries, return verification, and failure close within one borrowed controller operation; never quit from the controller or an unexpected prompt.
- Leave busy controllers untouched, propagate cancellation, preserve independent cleanup/close failures, and require net-connector 0.11.1 for the optional AP adapter.
- Skip AP credential and adapter setup for empty inventories; keep AP setup errors separate from controller connection failures.

- Snapshot controller identity and AP selection before external session callbacks can mutate caller-owned inputs.
- Remove the mandatory net-connector dependency and default AP adapter loading; inject AP readers through `Collector.new(ap_session:)` and load `wireless/ap_session` explicitly when needed.
- Use the current shared parser and driver APIs without version constraints in the gemspec; applications own their deployment lockfiles.
- Reject pagination and editing controls before parsing H3C/Huawei runtime facts; retain damaged configuration source lines and mark their enclosing captures incomplete.

- Use the shared `CtxParser::Configuration`, `Results`, and `Commands` names and dimension indexes where applicable.

- Simplify H3C parsing to `Parser` and `RecordParser`, with shared `Authentication` field definitions; retain device-command parser names.
- Name H3C source documents `H3c::Document`, group Huawei parsing under `Huawei::Profile` and command-mapped `Huawei::Parsers`, and use `RuntimeParser` directly for H3C observations.
- Reject numeric overflow in measurements and rate conversions while retaining unrelated client facts.

- Rename domain APIs directly; callers must use the new names (no compatibility aliases).

- Expose seconds, Mbps, and MHz in measurement conversion names; keep ambiguous channel-only band evidence unknown.

- Name private collection operations by their scope: controller commands, AP neighbor batches, and individual AP neighbor reads.
- Breaking: map H3C AP/client online duration to `online_seconds`, and reserve AP `uptime_seconds` for the separate system uptime field.
- Preserve explicit composite authentication modes and opaque LLDP chassis identities instead of reducing their meaning.

### Fixed

- Keep repeated Radio capability labels within their VHT, HT, HE MCS, or operational-rate subsection; accept documented BSSID and bandwidth aliases.
- Keep Radio coverage incomplete when an AP has no reported Radio evidence; AP counts only establish the AP inventory.
- Validate compound channel settings before assignment, and clear all related flags when channel or MAC username-format declarations conflict.
- Bind AP LLDP captures and evidence to the requested command and AP identity, rejecting contradictory skipped-success receipts.

- Reject conflicting or malformed totals and conflicting converted runtime fields; ambiguous fields cannot be restored by later declarations.
- Reject contradictory singleton settings within a configuration block, retain invalid source locations, and stop ambiguous authentication derivation.
- Preserve wireless declarations under unknown parent scopes as incomplete evidence instead of claiming an empty configuration.
- Validate authentication modes, explicit IP address families, and VLAN membership ranges; keep domain references separate from authentication activation.
- Index configuration entities, template bindings, and AP name selection; append LLDP descriptions without repeated whole-string copies.
- Traverse unsupported configuration trees iteratively instead of consuming the Ruby call stack.
- Keep observation, snapshot, and projection display strings metadata-only; validate observation identities and detach snapshot hash defaults.
- Keep empty coverage scopes unknown and reject non-finite freshness windows.
- Snapshot platform/model before callbacks and prevent AP credentials from replacing the borrowed controller session.

- Recognize unsupported command responses at line boundaries without interpreting SSIDs or banner text as errors.
- Keep paginated or damaged configurations and their source captures incomplete.
- Copy validated AP credentials so later caller mutation cannot alter login interactions.

## 0.1.0 (2026-10-16)

### Added

- Controller configuration/runtime parsers, shared AP/radio views, and host-independent observations.
- Standalone RubyGems packaging under `wireless-rb` with the `wireless` require path and `Wireless` namespace.
- English and Chinese documentation, an offline example, and standalone RSpec/RuboCop development tasks.
- Linux/macOS CI, isolated package verification, and automatic RubyGems and GitHub Releases with identical artifacts.

### Fixed

- Keep MAC authentication passwords out of normalized results and require successful projection status for complete coverage.

### Changed

- Cross-module dependencies resolve through RubyGems/Bundler instead of relative sibling paths.
- Motor persistence and application-specific adapters remain in the host application.
