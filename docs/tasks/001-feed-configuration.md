# Task 001: Feed configuration tables

Status: Completed.

## Objective

Create the instrument catalogue and desired subscription configuration for the first Zerodha feed slice. All subscriptions use `full` mode. Configuration will initially be loaded at feed startup.

Read `AGENTS.md`, `docs/project-brief.md`, and `docs/local-database.md` before implementation. Follow applicable project skills without restarting agreed design discussions.

## Existing infrastructure

- Local database: `intraday_streaming`, PostgreSQL with TimescaleDB.
- Application schema: `feed`; do not use `public`.
- Owner role: `streaming_owner` (NOLOGIN).
- Runtime role: `streaming_app` (configuration reads only).
- `.env.local` contains runtime credentials; do not print, commit, or embed them in migrations.
- Default privileges grant SELECT to `streaming_app` on tables created by `streaming_owner` in `feed`.

Use an authorized administrator connection for migrations and `SET LOCAL ROLE streaming_owner` inside the transaction. Runtime credentials are not migration credentials. Verify the connected database before applying SQL. Do not rerun `infra/db/bootstrap.sql`, recreate roles, or touch other databases.

## Schema contract

Create ordinary PostgreSQL tables, not hypertables. Use this DDL inside the migration transaction:

```sql
CREATE TABLE feed.instruments (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instrument_token bigint NOT NULL UNIQUE,
    exchange         text NOT NULL,
    trading_symbol   text NOT NULL,
    segment          text NOT NULL,
    instrument_type  text NOT NULL,
    expiry           date,

    CONSTRAINT instruments_token_range
        CHECK (instrument_token BETWEEN 1 AND 4294967295),
    CONSTRAINT instruments_exchange_symbol_unique
        UNIQUE (exchange, trading_symbol),
    CONSTRAINT instruments_metadata_nonempty
        CHECK (
            btrim(exchange) <> '' AND btrim(trading_symbol) <> ''
            AND btrim(segment) <> '' AND btrim(instrument_type) <> ''
        )
);

CREATE TABLE feed.subscriptions (
    instrument_id bigint PRIMARY KEY
        REFERENCES feed.instruments (id),
    mode          text NOT NULL DEFAULT 'full',
    enabled       boolean NOT NULL DEFAULT true,

    CONSTRAINT subscriptions_full_mode
        CHECK (mode = 'full')
);
```

The internal instrument ID is distinct from the provider token. Exchange plus trading symbol identifies a catalogue entry for this slice. Expiry is nullable for cash instruments. A subscription is desired configuration, not evidence of active connection state. One row per instrument is sufficient for the initial logical feed.

Catalogue synchronization and derivative token reuse are deferred. Do not implement refresh by blindly changing an existing instrument identity based on token reuse.

## Read contract

Document and verify this query; application Go code is outside this task:

```sql
SELECT i.instrument_token, s.mode
FROM feed.subscriptions AS s
JOIN feed.instruments AS i ON i.id = s.instrument_id
WHERE s.enabled
ORDER BY i.instrument_token;
```

## Deliverables

1. A versioned SQL migration under `infra/db/migrations/` with transactional execution, owner-role switching, and stop-on-error execution instructions.
2. A separate, repeatable local simulator seed under `infra/db/seeds/`. Use clearly synthetic instruments and tokens, two enabled full-mode subscriptions and one disabled subscription. State that these fixtures must not be used for live Kite subscriptions. Never overwrite existing catalogue entries on token or symbol conflicts; fail visibly on incompatible fixture data.
3. SQL verification under `infra/db/checks/` for meaningful constraints and the enabled-subscription query. Roll back temporary test rows; avoid persistent schema objects and destructive tests.
4. Update `docs/local-database.md` with exact migration, seed, and verification commands, plus a separate real app-login check. Explain migration rerun behavior; do not silently hide schema drift with `IF NOT EXISTS`.
5. Apply and verify on the existing local database using authorized access, then report files changed, commands run, and outcomes. If access is blocked, preserve artifacts and report unapplied steps rather than claiming success.

Keep this task SQL-only; do not add a Go module, migration framework, or dependencies merely for these two tables.

## Acceptance criteria

- Both tables exist only in `feed` and are owned by `streaming_owner`.
- Duplicate tokens and duplicate exchange/symbol pairs are rejected.
- Invalid token ranges, empty required metadata, unknown instrument references, duplicate subscriptions, and non-full modes are rejected.
- Expiry may be NULL for cash instruments; valid dated futures metadata is accepted.
- The startup query returns only enabled full-mode subscriptions in deterministic token order.
- The fixture seed can be rerun without duplicating rows or overwriting unrelated data.
- An actual `streaming_app` login can execute the query but cannot INSERT, UPDATE, DELETE, or create schema objects; `public` access remains disabled.
- Constraint checks leave no test data behind. No credentials appear in committed files or reported output.

## Outside scope

Tick/depth tables, retention, hypertables, market parsing, WebSocket client or simulator implementation, gRPC, durable delivery, exactly-once protocols, dynamic configuration, worker assignment, cloud provisioning, and live trading.

Protocol reference for future feed work: https://kite.trade/docs/connect/v3/websocket/
