# Local database

Database: `intraday_streaming`, on local PostgreSQL port 5432.

| Object | Purpose |
| --- | --- |
| `streaming_owner` | Non-login database/schema owner; migrations use `SET LOCAL ROLE streaming_owner` through an authorized administrator |
| `streaming_app` | Runtime login; connect and read configuration tables in `feed` |
| `feed` | Application configuration tables (`feed.instruments`, `feed.subscriptions`) |
| `extensions` | TimescaleDB extension objects |

The app has no public-schema access or schema creation privileges. Its search path is `pg_catalog, feed`; prefer schema-qualified SQL. Default SELECT grants apply to tables created by `streaming_owner` in `feed`, not tables created by other roles.

Local credentials are in `.env.local`, excluded from Git and restricted to the file owner. This is a shell-compatible environment file; load its variables before running `psql` or the app. Do not print, commit, or log its contents. Live Zerodha credentials are not configured.

`infra/db/bootstrap.sql` records initial provisioning with a password placeholder. It is a one-time administrator script, not an idempotent migration. Replace the placeholder securely before using it on a fresh instance. Do not rerun against the existing database.

## Configuration tables

The feed configuration tables are ordinary PostgreSQL tables in the `feed` schema:
- `feed.instruments`: Instrument catalogue containing provider token (1 to 4294967295), exchange, trading symbol, segment, instrument type, and optional expiry date.
- `feed.subscriptions`: Desired subscription state per instrument (`mode` restricted to `'full'`, `enabled` boolean).

## Migration execution

Run migrations using an authorized administrator connection (e.g. database superuser or admin):

```bash
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/migrations/001_feed_configuration.sql
```

### Rerun behavior

Migrations intentionally avoid `IF NOT EXISTS`. Attempting to rerun a migration against a database where tables already exist will fail visibly on table creation and abort the transaction, preventing silent schema drift.

## Simulator fixtures (seed)

A repeatable local simulator seed provides synthetic instruments and subscriptions for local testing:

```bash
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/seeds/001_simulator_feed.sql
```

> **Warning:** Fixture instruments and tokens are synthetic (`SIM` exchange) and **must not** be used for live Kite subscriptions.

### Repeatability and conflict safety

- The seed script is repeatable: rerunning against an already-seeded database inserts zero duplicate rows (`INSERT 0 0`) and never overwrites existing catalogue entries.
- If existing catalogue entries or subscriptions conflict with fixture tokens or symbols, the script raises an explicit exception and aborts the transaction.

## Verification checks

### 1. Schema, ownership, and constraint verification

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

### 2. Runtime role (`streaming_app`) permissions check

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

## Feed startup read query

The feed engine reads enabled full-mode subscriptions on startup using:

```sql
SELECT i.instrument_token, s.mode
FROM feed.subscriptions AS s
JOIN feed.instruments AS i ON i.id = s.instrument_id
WHERE s.enabled
ORDER BY i.instrument_token;
```
