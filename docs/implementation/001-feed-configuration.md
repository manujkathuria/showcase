# Implementation 001: Feed configuration tables

Task Reference: [docs/tasks/001-feed-configuration.md](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/tasks/001-feed-configuration.md)  
Status: Completed  
Implemented: 2026-10-09  

---

## 1. Overview

Implemented the instrument catalogue (`feed.instruments`) and desired subscription configuration (`feed.subscriptions`) tables for the Zerodha feed slice on the local PostgreSQL database (`intraday_streaming`).

This implementation is SQL-only, conforming strictly to the schema contract, role boundaries, and security rules established in [docs/local-database.md](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/local-database.md) and [AGENTS.md](file:///Users/manujkathuria/workspace/gidh/intraday-trading/AGENTS.md).

---

## 2. Artifacts Produced

| Type | Path | Purpose |
| --- | --- | --- |
| **Migration** | [`infra/db/migrations/001_feed_configuration.sql`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/infra/db/migrations/001_feed_configuration.sql) | Creates `feed.instruments` and `feed.subscriptions` tables under `streaming_owner` with database guard. |
| **Fixture Seed** | [`infra/db/seeds/001_simulator_feed.sql`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/infra/db/seeds/001_simulator_feed.sql) | Repeatable seed with synthetic tokens and subscriptions for simulator testing with database guard. |
| **Constraint Checks** | [`infra/db/checks/001_verify_constraints.sql`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/infra/db/checks/001_verify_constraints.sql) | Validates schema location, table ownership, constraint rejections, and programmatic assertions on startup query ordering with rollback. |
| **Runtime Permissions** | [`infra/db/checks/002_verify_runtime_permissions.sql`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/infra/db/checks/002_verify_runtime_permissions.sql) | Explicitly asserts `current_user = 'streaming_app'`, denied `public` usage/create, query result correctness, and mutation/DDL rejection. |
| **Documentation** | [`docs/local-database.md`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/local-database.md) | Updated database docs with table specifications, execution commands, rerun semantics, and seed guidance. |

---

## 3. Engineering Decisions & Behavior

### Database Guard & Safety
- **Database-Name Guard**: Both migration and seed execute an immediate pre-flight check asserting `current_database() = 'intraday_streaming'`. Execution against any other connected database (such as `postgres` or template databases) aborts before role switching or mutations occur.

### Schema & Role Management
- **Role Isolation**: The migration switches execution context using `SET LOCAL ROLE streaming_owner` inside a transaction. The tables are owned exclusively by `streaming_owner` in the `feed` schema, never in `public`.
- **Default Privileges**: Inherits default SELECT grants for `streaming_app` on tables created by `streaming_owner` in `feed`.
- **Schema Drift Protection**: Intentionally omits `IF NOT EXISTS` in the migration DDL. Rerunning against an already migrated schema fails visibly, surfacing drift or accidental rerun attempts rather than silently skipping them.

### Simulator Fixtures & Repeatability
- **Synthetic Fixtures**: Fixture instruments use the synthetic exchange code `SIM` (tokens `9900001`, `9900002`, `9900003`). Two subscriptions are enabled in `full` mode and one is disabled.
- **Repeatability**: The seed checks existing rows before inserting. Rerunning the seed on an identical catalogue produces `INSERT 0 0` without duplicate rows or altered identifiers.
- **Conflict Detection**: Prior to insertion, the seed inspects existing rows matching the token or symbol. If conflicting values are encountered, an exception is raised immediately to prevent overwriting existing data.
- **Safety Notice**: Fixtures are explicitly documented as synthetic and must not be used for live Kite subscriptions.

### Verification Strategy & Assertions
- **Subtransaction Testing**: Constraint tests (`001_verify_constraints.sql`) use PL/pgSQL exception handling blocks to assert that invalid data (out-of-range tokens, whitespace metadata, duplicate keys, invalid modes, dangling foreign keys) triggers expected violations.
- **Programmatic Query Assertions**: Rather than merely printing query output, checks in both `001_verify_constraints.sql` and `002_verify_runtime_permissions.sql` programmatically assert that the startup query returns exactly 2 enabled rows (`9900001` and `9900002`), strictly ordered by token, with `mode = 'full'`, and excluding disabled token `9900003`.
- **Zero Artifact Residue**: All test fixtures inserted during verification are cleaned up and the entire transaction executes a `ROLLBACK`, leaving zero residual test rows in the database.
- **Explicit Runtime Role Verification**: `002_verify_runtime_permissions.sql` connects via `.env.local` credentials and programmatically asserts:
  - `current_user = 'streaming_app'`.
  - `has_schema_privilege('streaming_app', 'public', 'USAGE') = false` and `has_schema_privilege('streaming_app', 'public', 'CREATE') = false`.
  - Attempts to `INSERT`, `UPDATE`, `DELETE`, or `CREATE TABLE` in `feed` or `public` raise `insufficient_privilege`.

---

## 4. Verification Record

| Check | Command | Observed Result |
| --- | --- | --- |
| Database Guard (Wrong DB) | `psql -v ON_ERROR_STOP=1 -d postgres -f infra/db/migrations/001_feed_configuration.sql` | Aborted with `ERROR: Refusing migration: expected database "intraday_streaming", connected to "postgres"` |
| Migration Application | `psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/migrations/001_feed_configuration.sql` | `CREATE TABLE` x2; Tables owned by `streaming_owner` |
| Migration Rerun Defense | `psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/migrations/001_feed_configuration.sql` | Aborted with `ERROR: relation "instruments" already exists` |
| Seed Fixtures | `psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/seeds/001_simulator_feed.sql` | 3 instruments and 3 subscriptions seeded |
| Seed Repeatability | `psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/seeds/001_simulator_feed.sql` | `INSERT 0 0`; zero duplicates created |
| Seed Conflict Detection | Seed execution against modified token symbol | Aborted with `ERROR: Incompatible instrument catalogue data detected...` |
| Constraint & Query Assertion | `psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/001_verify_constraints.sql` | All constraints validated; enabled query asserted for exact token set & ordering; test rows rolled back |
| Runtime Role & Permissions | `env $(grep -v '^#' .env.local \| xargs) psql -v ON_ERROR_STOP=1 -f infra/db/checks/002_verify_runtime_permissions.sql` | Role `streaming_app` asserted; `public` USAGE/CREATE confirmed denied; enabled query asserted; mutations & DDL rejected with `insufficient_privilege` |
