# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

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
