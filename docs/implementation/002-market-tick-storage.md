# Implementation 002: Tick and depth tables and indexes

Task Reference: [docs/tasks/002-market-tick-storage.md](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/tasks/002-market-tick-storage.md)
Status: Implementation complete; pending independent review
Implemented: 2026-10-09

---

## 1. Overview

Implemented the market data storage layer for live decoded stock and futures quote packets and their snapshot order depth in the local PostgreSQL database (`intraday_streaming`):
- Created schema `market` owned by `streaming_owner`.
- Created ordinary PostgreSQL tables `market.live_ticks` and `market.order_depth`.
- Enforced stream identity, sequencing, price scaling, depth level bounds, and foreign key relationships.
- Added targeted B-tree indexes for latest-tick queries, instrument history, and deterministic keyset replay.
- Configured read-only permissions for runtime role `streaming_app`.
- Created parameterized `EXPLAIN (ANALYZE, BUFFERS)` query-plan scripts for the five core query shapes with caller parameter preservation.

Bulk synthetic data generation is decoupled into [Task 003](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/tasks/003-synthetic-market-seed.md); representative performance measurements at 100k/1M scale are deferred to that task.

---

## 2. Artifacts Produced

| Type | Path | Purpose |
| --- | --- | --- |
| **Migration** | [`infra/db/migrations/002_market_tick_storage.sql`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/infra/db/migrations/002_market_tick_storage.sql) | Creates schema `market`, tables `market.live_ticks` and `market.order_depth`, indexes, and runtime grants with database guard. |
| **Correctness Checks** | [`infra/db/checks/003_market_tick_storage_checks.sql`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/infra/db/checks/003_market_tick_storage_checks.sql) | Rollback-only validation of ownership, constraint rejection, tied timestamps validity, and 5 query shapes with isolated fixtures and exact identity/completeness assertions. |
| **Query Plans Script** | [`infra/db/checks/004_market_query_plans.sql`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/infra/db/checks/004_market_query_plans.sql) | Parameterized SELECT and `EXPLAIN (ANALYZE, BUFFERS)` scripts for the five required query shapes, with caller parameter preservation and target DB guard. |
| **Runtime Permissions** | [`infra/db/checks/005_verify_market_runtime_permissions.sql`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/infra/db/checks/005_verify_market_runtime_permissions.sql) | Validates `streaming_app` USAGE on `market`, SELECT on tables, denied public privileges, and denied mutation/DDL operations. |
| **Documentation** | [`docs/local-database.md`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/local-database.md) | Updated with market schema specification, migration execution, query plan scripts, and verification commands. |

---

## 3. Engineering Decisions & Index Rationale

### Storage Contract & Hypertables
- **Ordinary PostgreSQL Tables**: Implemented as ordinary tables rather than TimescaleDB hypertables. This ensures referential integrity (`order_depth.tick_id -> live_ticks.id`) without hypertable foreign-key partition restrictions. Hypertable chunking, compression, and retention are deferred until the joint tick/depth lifecycle is formally specified.
- **Identity & Deduping**: `market.live_ticks` uses a surrogate identity PK (`id bigint GENERATED ALWAYS AS IDENTITY`). Packet uniqueness within a publishing session is enforced via `UNIQUE (stream_id, sequence)`. Timestamps and prices are intentionally decoupled from identity: tied timestamps and repeated price updates are valid market phenomena and are accepted.
- **Scaled Prices**: All prices (`last_price`, `average_price`, OHLC, depth prices) are stored as raw nonnegative `bigint` integers. Floating-point types are avoided to preserve wire precision.

### Depth Snapshot Layout & Index Support
- **Composite Primary Key**: `market.order_depth` uses `PRIMARY KEY (tick_id, side, level)`. This enforces uniqueness per level and creates a B-tree index where `tick_id` is the leading column.
- **No Standalone Index on `tick_id`**: A redundant standalone index on `tick_id` is omitted because index scans on `tick_id` are efficiently served by the leading column of the primary key index.
- **PostgreSQL Heap Storage**: Note that in PostgreSQL's heap-organized storage model, B-tree indexes order index entries rather than physically clustering table heap pages on disk.
- **Writer Atomicity Contract**: Row constraints enforce valid sides (`bid`, `ask`), levels (`1..5`), and nonnegativity, but cannot enforce cardinality across rows. Inserting a tick and its exactly 10 snapshot depth levels in a single transaction is a writer responsibility.

### Index Selection
1. **Instrument Latest & History**: `CREATE INDEX live_ticks_instrument_received_idx ON market.live_ticks (instrument_id, received_at DESC, id DESC);`
   - Serves `ORDER BY received_at DESC, id DESC LIMIT 1` (latest tick) via index scan ordering.
   - Serves bounded half-open range queries `WHERE instrument_id = :id AND received_at >= :start AND received_at < :end ORDER BY received_at, id` via backward index scan without external sort.
2. **Deterministic Replay**: `CREATE INDEX live_ticks_replay_idx ON market.live_ticks (received_at, id);`
   - Serves cross-instrument stream replay with keyset pagination `received_at >= :start AND (received_at, id) > (:cursor_time, :cursor_id) AND received_at < :end`.
   - Avoids quadratic degradation of `OFFSET` pagination for deep replays.
   - Provides deterministic tie-breaking on tied application receive timestamps.

---

## 4. Verification Evidence

### 1. Correctness & Constraint Checks
Command:
```bash
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/003_market_tick_storage_checks.sql
```
Observed Output:
```text
BEGIN
DO
NOTICE:  CHECK 1 PASS: Schema and tables exist in market and are owned by streaming_owner
DO
NOTICE:  CHECK 2 PASS: All table constraint tests passed
DO
NOTICE:  CHECK 3 PASS: All five query shapes validated with exact expected identities and snapshot completeness
DO
ROLLBACK
```
*Validated:*
- Schema and tables owned by `streaming_owner`; public schema clean.
- Dangling instrument FK rejected.
- Dangling tick FK in `order_depth` rejected.
- Nonpositive sequence (`<= 0`) rejected.
- Negative prices, quantities, volume, and open interest rejected.
- Duplicate `(stream_id, sequence)` rejected.
- Duplicate depth `(tick_id, side, level)` rejected.
- Invalid depth side (not `'bid'`/`'ask'`) and level (`< 1` or `> 5`) rejected.
- Equal timestamps and identical prices across different sequences verified as valid.
- Query shapes verified with isolated dedicated fixtures:
  - Latest tick verified with exact sequence (`104`), price (`102`), and tick ID.
  - History range verified for exact ordered ID sequence (`[t1, t2]`).
  - Replay keyset pagination verified across tied timestamps (`09:15:01` on `t2` and `t3`) producing exact ordered sequence `[t1, t2]` on Page 1 and `[t3, t4]` on Page 2 without gaps or duplicates.
  - Snapshot completeness verified: all 10 depth levels verified per tick with exact price ladders.
  - Joined replay verified: subquery-limited 2 ticks produce exactly 20 depth rows.
  - Verified independence from `feed.subscriptions` configuration (tested on disabled and unconfigured instruments).
- All temporary rows rolled back (`ROLLBACK`).

### 2. Runtime Role Permissions Check
Command:
```bash
env $(grep -v '^#' .env.local | xargs) psql -v ON_ERROR_STOP=1 -f infra/db/checks/005_verify_market_runtime_permissions.sql
```
Observed Output:
```text
BEGIN
DO
NOTICE:  CHECK 1 PASS: Verified connected as role "streaming_app"
DO
NOTICE:  CHECK 2 PASS: Verified public schema USAGE and CREATE are denied to streaming_app
DO
NOTICE:  CHECK 3 PASS: Verified USAGE on market and SELECT on market tables granted to streaming_app
DO
 live_ticks_read_count
-----------------------
                     0
 order_depth_read_count
------------------------
                      0
NOTICE:  CHECK 5 PASS: All unauthorized mutation and DDL attempts on market correctly rejected
DO
ROLLBACK
```
*Validated:*
- Connected as `streaming_app` on `intraday_streaming`.
- Public schema `USAGE` and `CREATE` denied.
- `market` schema `USAGE` and table `SELECT` granted.
- `INSERT`, `UPDATE`, `DELETE`, and `CREATE TABLE` in `market` and `public` rejected with `insufficient_privilege`.

### 3. Query Plan Executability & Parameter Preservation
Commands:
```bash
# Default parameter run:
psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/004_market_query_plans.sql

# Custom caller parameter run:
psql -v ON_ERROR_STOP=1 -d intraday_streaming -v instrument_id=2 -v page_limit=25 -f infra/db/checks/004_market_query_plans.sql
```
*Validated:*
- Target database guard confirmed.
- Caller variables (e.g. `-v instrument_id=2 -v page_limit=25`) preserved and reflected in executed plans via conditional defaults (`\if :{?variable}`).
- Query shapes 1, 2, and 3 use targeted B-tree indexes (`live_ticks_instrument_received_idx` and `live_ticks_replay_idx`).
- Query 5 limits ticks first in subquery before joining depth.

---

## 5. Deferred Work & Next Steps

- **Representative Performance Measurements**: Full-scale buffer hit/read ratios, cache-controlled execution times, and planner choices under large volumes (100k ticks, 1M depth rows) are deferred to [Task 003](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/tasks/003-synthetic-market-seed.md), which implements the Go synthetic data generator.
- **Independent Verification**: Independent review and verification are to be recorded separately by the delivery lead in `docs/verification/002-market-tick-storage.md`.
