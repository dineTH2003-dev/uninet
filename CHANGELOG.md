# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - 2026-09-18

### Added
- Core network state and active SSID detection module using NetworkManager (`nmcli`).
- Connectivity and captive portal probing engine using RFC 8908/8910 compliant endpoints and HTTP redirect/payload inspection.
- Pluggable authentication architecture with `BaseAuthProvider` and extensible provider registry.
- Generic HTML form extractor for automated login analysis and token extraction.
- Unified CLI interface (`uninet status`, `uninet test`, `uninet probe --dump`, `uninet login`, `uninet logout`).
- Human-readable and JSON output formats (`--json`) for easy shell scripting and diagnostics.
- Initial NetworkManager dispatcher hook and `systemd` user service templates.
- Comprehensive test suite covering network state parsing, captive portal detection, and CLI subcommands with mocks.
- Architecture and portal analysis documentation (`docs/architecture.md`, `docs/portal-analysis.md`, `docs/development.md`).
