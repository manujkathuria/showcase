# Local database

Database: `intraday_streaming`, on local PostgreSQL port 5432.

| Object | Purpose |
| --- | --- |
| `streaming_owner` | Non-login database/schema owner; migrations use `SET LOCAL ROLE streaming_owner` through an authorized administrator |
| `streaming_app` | Runtime login; connect and read configuration tables in `feed` and ticks/depth in `market` |
| `feed` | Application configuration tables (`feed.instruments`, `feed.subscriptions`) |
| `market` | Ingested market data tables (`market.live_ticks`, `market.order_depth`) |
| `extensions` | TimescaleDB extension objects |

The app has no public-schema access or schema creation privileges. Its search path is `pg_catalog, feed`; prefer schema-qualified SQL. Default SELECT grants apply to tables created by `streaming_owner` in `feed` and `market`, not tables created by other roles.

Local credentials are in `.env.local`, excluded from Git and restricted to the file owner. This is a shell-compatible environment file; load its variables before running `psql` or the app. Do not print, commit, or log its contents. Live Zerodha credentials are not configured.

`infra/db/bootstrap.sql` records initial provisioning with a password placeholder. It is a one-time administrator script, not an idempotent migration. Replace the placeholder securely before using it on a fresh instance. Do not rerun against the existing database.

## Schema contracts

### 1. Feed configuration (`feed` schema)
Ordinary PostgreSQL tables:
- `feed.instruments`: Instrument catalogue containing provider token (1 to 4294967295), exchange, trading symbol, segment, instrument type, and optional expiry date.
- `feed.subscriptions`: Desired subscription state per instrument (`mode` restricted to `'full'`, `enabled` boolean).

### 2. Market tick and depth storage (`market` schema)
Ordinary PostgreSQL tables (TimescaleDB hypertables deferred pending joint retention design):
- `market.live_ticks`: Live decoded stock/futures quote packets. Primary key `id` (identity); unique constraint on `(stream_id, sequence)` to reject duplicate stream packets; foreign key to `feed.instruments(id)`.
  - Indexes:
    - B-tree `(instrument_id, received_at DESC, id DESC)` for instrument-local latest and bounded-history queries.
    - B-tree `(received_at, id)` for deterministic replay across instruments.
- `market.order_depth`: Snapshot depth levels (up to 5 bids and 5 asks per tick).
  - Primary key `(tick_id, side, level)` serving both uniqueness and snapshot retrieval. Foreign key to `market.live_ticks(id)`.

## Migration execution

Run migrations using an authorized administrator connection (e.g. database superuser or admin):

```bash
# Migration 001: Feed configuration
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/migrations/001_feed_configuration.sql

# Migration 002: Market tick and depth storage
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/migrations/002_market_tick_storage.sql
```

### Rerun behavior

Migrations intentionally avoid `IF NOT EXISTS`. Attempting to rerun a migration against a database where schemas or tables already exist will fail visibly on creation and abort the transaction, preventing silent schema drift.

## Feed simulator fixtures (SQL seed)

A repeatable local simulator seed provides synthetic instruments and subscriptions for feed testing:

```bash
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/seeds/001_simulator_feed.sql
```

> **Warning:** Fixture instruments and tokens are synthetic (`SIM` exchange) and **must not** be used for live Kite subscriptions.

### Repeatability and conflict safety

- The seed script is repeatable: rerunning against an already-seeded database inserts zero duplicate rows (`INSERT 0 0`) and never overwrites existing catalogue entries.
- If existing catalogue entries or subscriptions conflict with fixture tokens or symbols, the script raises an explicit exception and aborts the transaction.

## Go synthetic market seed generator

A high-performance Go CLI (`cmd/seed-generator`) loads deterministic, protocol-representable ticks and order depth into `market.live_ticks` and `market.order_depth` for query profiling.

### 1. Build
```bash
go build -o bin/seed-generator ./cmd/seed-generator
```

### 2. Smoke run (small verification preset)
Generates 2 synthetic instruments × 50 ticks = 100 ticks and 1,000 depth rows in ~20ms:
```bash
./bin/seed-generator -smoke
```

### 3. Full baseline load
Generates 10 synthetic instruments × 10,000 ticks = 100,000 ticks and 1,000,000 depth rows:
```bash
./bin/seed-generator \
  -instruments=10 \
  -ticks-per-instrument=10000 \
  -batch-size=1000 \
  -stream-id="c0000000-0000-0000-0000-000000000003"
```

### Idempotency & safety
- The generator verifies the connected database is `intraday_streaming` before modifying tables.
- Rerunning with the same stream UUID detects complete data and skips insertion (`Idempotent skip`).
- Partial or conflicting stream states abort with a visible error.

## Verification checks

### 1. Feed schema, ownership, and constraint verification

Run with an authorized administrator connection:

```bash
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/001_verify_constraints.sql
```

This verification:
- Guards against execution on the wrong database (`intraday_streaming` required).
- Confirms table existence in `feed` and ownership by `streaming_owner`.
- Confirms tables do not exist in `public`.
- Validates constraint rejection: token out of range (`0`, `> 4294967295`), blank/whitespace metadata, duplicate tokens, duplicate `(exchange, trading_symbol)` pairs, unknown instrument references in subscriptions, invalid modes (non-`full`), and duplicate subscriptions.
- Validates NULL expiry acceptance for cash instruments and dated expiry acceptance for futures.
- Programmatically asserts that the startup read query produces exact expected rows (`9900001` and `9900002` in `full` mode), strictly ordered by token, excluding disabled subscriptions.
- Executes all mutation tests inside a transaction that is rolled back (`ROLLBACK`), leaving no temporary test rows behind.

### 2. Feed runtime role (`streaming_app`) permissions check

Run using runtime credentials loaded from `.env.local`:

```bash
env $(grep -v '^#' .env.local | xargs) psql -v ON_ERROR_STOP=1 -f infra/db/checks/002_verify_runtime_permissions.sql
```

This verification:
- Guards against execution on the wrong database (`intraday_streaming` required).
- Explicitly asserts `current_user = 'streaming_app'`.
- Programmatically asserts that `streaming_app` has neither `USAGE` nor `CREATE` privileges on the `public` schema (`has_schema_privilege = false`).
- Programmatically asserts that the startup query returns the exact expected enabled subscriptions.
- Confirms `streaming_app` is blocked with `insufficient_privilege` when attempting `INSERT`, `UPDATE`, or `DELETE` on `feed.instruments` and `feed.subscriptions`.
- Confirms `streaming_app` is blocked from creating tables in `feed` or `public`.

### 3. Market schema, ownership, and constraint verification

Run with an authorized administrator connection:

```bash
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/003_market_tick_storage_checks.sql
```

This verification:
- Guards database name (`intraday_streaming`).
- Confirms schema `market` and tables `live_ticks`, `order_depth` are owned by `streaming_owner`.
- Confirms constraint enforcement: nonpositive sequence, negative prices/quantities/OI, dangling FKs, duplicate `(stream_id, sequence)`, invalid depth side/level, negative depth values, and duplicate depth levels.
- Validates that equal timestamps and repeated prices are permitted across distinct sequence numbers.
- Uses a rollback-only fixture to validate all 5 query shapes: latest tick, instrument history range, replay keyset pagination across tied timestamps, depth snapshots, and joined replay with depth.

### 4. Market query plan inspection

Run with an authorized administrator connection:

```bash
# Default parameters:
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/004_market_query_plans.sql

# Custom parameters:
psql -v ON_ERROR_STOP=1 -d intraday_streaming \
  -v instrument_id=83 \
  -v page_limit=50 \
  -f infra/db/checks/004_market_query_plans.sql
```

Inspects `EXPLAIN (ANALYZE, BUFFERS)` plans for all 5 query shapes. Parameter overrides passed via `-v` are preserved by conditional defaults (`\if :{?variable}`).

### 5. Market runtime role (`streaming_app`) permissions check

Run using runtime credentials loaded from `.env.local`:

```bash
env $(grep -v '^#' .env.local | xargs) psql -v ON_ERROR_STOP=1 -f infra/db/checks/005_verify_market_runtime_permissions.sql
```

This verification:
- Confirms `streaming_app` has `USAGE` on schema `market` and `SELECT` on `market.live_ticks` and `market.order_depth`.
- Confirms `streaming_app` is blocked from `INSERT`, `UPDATE`, or `DELETE` on market tables.
- Confirms `streaming_app` is blocked from creating tables in `market` or `public`.

## Feed startup read query

The feed engine reads enabled full-mode subscriptions on startup using:

```sql
SELECT i.instrument_token, s.mode
FROM feed.subscriptions AS s
JOIN feed.instruments AS i ON i.id = s.instrument_id
WHERE s.enabled
ORDER BY i.instrument_token;
```
