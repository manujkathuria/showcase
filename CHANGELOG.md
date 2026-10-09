# Changelog

## [0.1.0](https://github.com/manujkathuria/showcase/releases/tag/v0.1.0) — 2026-10-09

Initial database configuration and engineering-workflow snapshot.

### Added

- Local PostgreSQL/TimescaleDB provisioning for `intraday_streaming`, with separate owner and runtime roles, application objects in `feed`, and extension objects in `extensions`.
- Instrument catalogue and full-mode subscription tables, with transactional migration and read-only application permissions.
- Repeatable synthetic simulator fixtures and SQL checks for constraints, subscription query results, and runtime permissions.
- Project brief, database documentation, implementation task, implementation report, and independent verification record.
- `AGENTS.md` and the project-framing skill for incremental agent-assisted development.
- Git initialization and local credential exclusions.

### Verification status

The initial constraint and runtime-permission checks passed. The tagged snapshot includes follow-up database guards and explicit assertions; independent verification of those changes and review closure remain pending in [the verification record](docs/verification/001-feed-configuration.md).

### Scope

This version contains configuration infrastructure and documentation. The WebSocket feed, processor, sinks, and durable delivery protocol are not implemented.
