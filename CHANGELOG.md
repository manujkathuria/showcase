# Changelog

## [0.1.1](https://github.com/manujkathuria/showcase/releases/tag/v0.1.1) — 2026-10-09

### Added

- Tick and depth snapshot tables in `market`, with targeted indexes, constraints, read-only runtime grants, and query-plan scripts.
- Go synthetic seed generator with reproducible inputs, reusable batches, pipelined tick inserts, and depth COPY writes.
- Go skills for data ownership, struct alignment, stack/heap decisions, and I/O batching; automatic routing in `AGENTS.md` version 4.
- Task, implementation, and review documents for market storage and seed generation, plus a separate database-performance task.

### Changed

- Excluded generated binaries from Git.

### Verification status

Market constraint and runtime-permission checks passed. Generator tests passed and its generation benchmark reported zero allocations. Full seed-generator acceptance, review closure, and comparative database performance remain pending; see [market review](docs/verification/002-market-tick-storage.md) and [seed I/O review](docs/verification/003-seed-io-review.md).

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
