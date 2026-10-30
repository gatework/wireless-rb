# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

## Unreleased

## 0.9.0 (2026-10-30)

- Adopt schema 4 Target/Source contracts, canonical `h3c` identity and shared configuration sessions. AP provenance stores domain metadata under `context`; operational status is `:online`, `:offline` or `:unknown`. Use explicit `channel_width_mhz` and `utilization_percent`. Reuse an immutable duplicate-aware configuration index for change candidates; reject unknown change fields. Require connector 0.21 for collection.

## 0.8.0 (2026-10-29)

- Load the dimension registry explicitly for standalone offline review; aggregate concurrent collection reports in a stable device order.

- Compose the shared snapshot contract, remove the synthetic collection observation and reject unknown runtime dimensions.
- Delegate interactive apply to ctx_cli and resolve credentials through net-connector. Require a named --item and adjacent SHA256 checksum.
- Aggregate eligible template changes into schema 3 plan.json, retaining a configuration fingerprint per device. Regenerate all old reports and plans.

## 0.7.0 (2026-10-29)

- Move RuntimeParser platform to construction; add command provenance to parse/parse_many. Rename Snapshot Ruby members to observations/observation while retaining dimensions in persisted reports. Add Collector#collect_session for borrowed sessions. Use Catalog and shared Credentials in CLI; reject selected duplicate addresses across platforms before connecting.

## 0.6.2 (2026-10-25)

- Extract AP neighbor selection, lazy credentials, receipt validation and coverage aggregation into ApCollection, preserving controller collection APIs and per-AP failure isolation.
- Validate and snapshot standalone AP selections before external callbacks; keep invalid requests and unmatched selections from accessing credentials.

## 0.6.1 (2026-10-24)

- Use shared CLI argument and diagnostic boundaries for apply; preserve exit status, cancellation and uncertain journals when stderr fails, without replaying commands.
- Consume JSON Pointer configuration provenance and leave shared gem dependency versions to host lockfiles.

## 0.6.0 (2026-10-23)

- Consume immutable string-keyed Runner summary documents throughout reports and progress callbacks.
- Require Runner 0.2, net-connector 0.18 and the coordinated English CLI protocol.

## 0.5.2 (2026-10-23)

- Migrate shared CLI entrypoints to ctx_cli 0.2.0 names without legacy aliases.
- Delegate offline review entrypoint orchestration to ctx_cli and bound external evidence and execution plan reads.
- Verify the entire permitted security delta, rejecting unrelated configuration drift and duplicate templates.
- Share evidence validation and JSON conversion with Runner; reject missing/mismatched targets and duplicate devices.
- Use explicit field separators and align CLI dependency floors with shared inventory support.
- Delegate shared command dispatch, option groups, initialization, terminal confirmation, offline IO and collection entrypoint flow to ctx_cli; retain domain and Runner responsibilities.

## 0.5.1 (2026-10-22)

- Delegate command dispatch, common options, initialization, terminal interaction, offline IO and collection entrypoint orchestration to ctx_cli 0.1.0.
- Keep domain policies, device capabilities and ctx_runner completion semantics in their existing layers.

- Delegate batch completion and cancellation/failure precedence to CtxRunner::Batch, keeping domain review and CLI presentation explicit.

## 0.5.0 (2026-10-22)

- Delegate batch completion and cancellation/failure precedence to CtxRunner::Batch, keeping domain review and CLI presentation explicit.

- Centralize inventory selection and CLI filters in Net::Connector::Inventory; add vendor/model inclusion, exclusion and matching modes.


- Delegate shared collection, evidence and execution contracts to ctx_runner.
- Preserve domain parsing, change policies, CLI layouts and connection ownership.

## 0.4.1 (2026-10-21)

- Compute a device configuration fingerprint once per review report when exporting multiple eligible plans; recompute for each subsequent report.
- Require exactly one complete configuration record before exporting executable plans, including when recommendations are supplied by a caller.
- Add repository-specific AGENTS.md and a review-to-plan serialization benchmark.

## 0.4.0 (2026-10-20)

- Sync newly created report directory entries before exposing an execution journal; stop before commands if directory durability cannot be confirmed.

- Reject missing or repeated apply session callbacks; success requires a completed configuration readback and commands are never replayed.

- Require ctx_driver 0.2.4+ for the current net-connector session protocol; CLI configuration and progress use net-connector 0.16.0.

- Rename the public configuration parser to `Wireless::Config` (`wireless/config`), updating CLI callers, examples, tests and documentation without compatibility aliases.

- 与 net-connector 备份共用批次终端进度、阶段心跳、异常分类和结束摘要；JSON 独立输出，终端故障保留安全诊断且不重采。初始化并发继承公共 `NC_PARALLEL`，不再把公共值或默认 4 固化进 YAML。

- CLI 配置统一使用 net-connector 0.16.0 的分层加载器，遵循命令行 > 进程环境 > YAML > `.env` > 默认值；支持公共配置复用、来源追踪及用户目录初始化。
- 清单来源与缓存 CLI 参数先覆盖低优先级环境字段，再校验有效值，避免已被覆盖的空环境值阻断运行。

- Make configuration script export opt-in with `--scripts`; add typed per-device plans and a TTY-only `apply` command with exact confirmation, fresh configuration guards, durable step checkpoints, no retry/automatic rollback, and configuration readback verification.

- Generate evidence-backed, review-only remediation recommendations during collection and through the offline `review --batch` command, including prerequisites, blocked parameters, conditional rollback, verification commands and source hashes. Configuration drafts are fully commented; no device changes are executed.

- Correct live H3C parsing: distinguish AP inventory totals from connection/license counters, accept blocked-client `Total entries`, and accumulate additive cipher suites/security IEs.
- Keep `VLAN ID` in `vlan` and `Service VLAN ID` in `service_vlan`; keep `SM power save` in `power_save` and its mode in `power_save_mode`. These distinct fields no longer remove one another as conflicting aliases. Consumers using the former aliases must select the appropriate field.

- Require Huawei table totals and evidence for every announced LLDP port; resolve connector compatibility through Registry aliases.
- Publish incomplete summary checkpoints before finalization; retain safe checkpoints, recover committed failures/cancellation, invalidate stale success on repeated finish, and report unconfirmed recovery without replaying device queries.
- Add traceable evidence specimens, independent literal expectations, private saved-capture replay and isolated targeted mutation verification tools.

- Centralize static and discovered device validation before public configuration output, reject false filter lists, and isolate state when a CLI runner is reused.
- Index completed hosts once when building pending-target summaries and document safe report publication states.
- Derive supported platforms and dimensions from Profile declarations; default controller collection to the selected platform while retaining legacy constants.
- Validate LLDP zero-neighbor declarations within their local port scope, preserving mixed-port facts and reporting contradictory counts.

- Add direct `bin/wireless.rb` execution with fixed project paths, embedded Netdisco/inventory settings, common environment defaults and inventory cache flags.

- Add the `wireless collect` / `wireless parse` CLI following VXLAN configuration, preview, concurrency, reporting and exit-code conventions.
- Support H3C/Huawei inventories and explicit AP LLDP using separate environment credentials; keep transport and dotenv optional.
- Package the executable, private initialization templates and CLI guide, and verify the installed entry point outside the checkout.
- Mark requested observations failed when a connector never yields a session instead of reporting an empty successful collection.

## 0.3.1 (2026-10-18)

- Clear Bundler bootstrap variables when verifying packages in an isolated gem installation, including calls made through bundle exec.

- Align the optional AP adapter with net-connector >= 0.13.0 and ctx_driver >= 0.2.2, using current terminal rendering and typed diagnostic codes while preserving controller leases and cancellation.

- Apply shared conflict handling to AP model, Radio capability, and software fields: equivalent repeats remain complete, while conflicting values are removed and cannot be restored by later repeats.
- Parse CLI records with explicit newline separators so host changes to Ruby `$/` cannot merge source rows or corrupt totals.

## 0.3.0 (2026-10-18)

- Name the internal H3C record builder `H3c::ConfigurationBuilder` (`wireless/h3c/configuration_builder`) and shared authentication field definitions `H3c::AuthenticationFields` (`wireless/h3c/authentication_fields`). Keep the public `Wireless::Configuration` entry point and `wireless/configuration` require path. Renamed internal constants and paths have no aliases.
- Rename Collector injection keywords to `ap_session_factory:` and `ap_credentials:`; update host integrations accordingly.
- Name internal operations for their actual behavior: build configuration scopes, mark unsupported subtrees, validate field blocks, parse table rows, capture AP LLDP, and restore the controller or close it.
- Keep NeighborParser caller errors distinct from malformed device evidence and unsupported platform dimensions.
- Validate observation timestamps as Time or nil during construction and value replacement.
- Restrict recognized Radio controls and service-template security commands to their own configuration scopes; misplaced commands leave captures incomplete.
- Centralize VLAN identity validation for H3C configuration/runtime and Huawei stations; reject VLAN 0 consistently.
- Preserve safe failure diagnostics and skipped execution from injected AP captures without repeating adapter errors.
- Scan LF command output incrementally for unsupported responses, avoiding a full line array and stopping at the first error.

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
