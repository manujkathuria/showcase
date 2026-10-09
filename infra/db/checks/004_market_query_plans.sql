-- Query Plan Preparation: Market tick and order depth query shapes
--
-- Execution instructions:
--   psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/004_market_query_plans.sql
--
-- Parameter override examples:
--   psql -v ON_ERROR_STOP=1 -d intraday_streaming \
--     -v instrument_id=2 \
--     -v start_time="'2026-10-09 09:15:00+05:30'" \
--     -v end_time="'2026-10-09 09:20:00+05:30'" \
--     -v cursor_time="'2026-10-09 09:15:00+05:30'" \
--     -v cursor_id=0 \
--     -v page_limit=50 \
--     -f infra/db/checks/004_market_query_plans.sql
--
-- Note on Performance Evidence:
--   On empty or small test fixtures, the PostgreSQL query planner may select Sequential
--   Scans or simple Index Scans. Full representative query plan measurements (buffer hits,
--   index scans, planning/execution times at 100k/1M scale) will be captured once the Go
--   seed generator loads the full synthetic dataset in Task 003.

\set ON_ERROR_STOP on

-- Guard: Ensure execution only against the intended database
DO $$
BEGIN
    IF current_database() <> 'intraday_streaming' THEN
        RAISE EXCEPTION 'Refusing query plans: expected database "intraday_streaming", connected to "%"', current_database();
    END IF;
END $$;

-- Preserve caller parameters if supplied via -v; apply fallback defaults if unset
\if :{?instrument_id}
\else
\set instrument_id 1
\endif

\if :{?tick_id}
\else
\set tick_id 1
\endif

\if :{?start_time}
\else
\set start_time '''2026-10-09 09:15:00+05:30'''
\endif

\if :{?end_time}
\else
\set end_time '''2026-10-09 09:30:00+05:30'''
\endif

\if :{?cursor_time}
\else
\set cursor_time '''2026-10-09 09:15:00+05:30'''
\endif

\if :{?cursor_id}
\else
\set cursor_id 0
\endif

\if :{?page_limit}
\else
\set page_limit 100
\endif

-- Echo effective parameters for reproducibility
\echo '------------------------------------------------------------'
\echo 'Executing Query Plans with Parameters:'
\echo '  instrument_id :' :instrument_id
\echo '  tick_id       :' :tick_id
\echo '  start_time    :' :start_time
\echo '  end_time      :' :end_time
\echo '  cursor_time   :' :cursor_time
\echo '  cursor_id     :' :cursor_id
\echo '  page_limit    :' :page_limit
\echo '------------------------------------------------------------'

-- ============================================================================
-- Query Shape 1: Latest tick per instrument
-- Targeted Index: live_ticks_instrument_received_idx (instrument_id, received_at DESC, id DESC)
-- Expected Plan at scale: Backward/Forward Index Scan with LIMIT 1.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    id, instrument_id, stream_id, sequence, received_at, exchange_at, last_trade_at,
    last_price, average_price, open_price, high_price, low_price, close_price,
    last_quantity, volume, total_buy_quantity, total_sell_quantity,
    open_interest, open_interest_high, open_interest_low
FROM market.live_ticks
WHERE instrument_id = :instrument_id
ORDER BY received_at DESC, id DESC
LIMIT 1;

-- ============================================================================
-- Query Shape 2: Instrument history (bounded half-open time range)
-- Targeted Index: live_ticks_instrument_received_idx (instrument_id, received_at DESC, id DESC)
-- Range condition: received_at >= :start_time AND received_at < :end_time
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    id, instrument_id, sequence, received_at, exchange_at,
    last_price, volume, open_interest
FROM market.live_ticks
WHERE instrument_id = :instrument_id
  AND received_at >= :start_time
  AND received_at < :end_time
ORDER BY received_at, id
LIMIT :page_limit;

-- ============================================================================
-- Query Shape 3: Replay across instruments with keyset pagination
-- Targeted Index: live_ticks_replay_idx (received_at, id)
-- Range & Keyset condition: received_at >= :start_time AND (received_at, id) > (:cursor_time, :cursor_id) AND received_at < :end_time
-- Note: Avoids OFFSET degradation for deep streaming replays.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    id, instrument_id, stream_id, sequence, received_at,
    last_price, volume, total_buy_quantity, total_sell_quantity
FROM market.live_ticks
WHERE received_at >= :start_time
  AND (received_at, id) > (:cursor_time, :cursor_id)
  AND received_at < :end_time
ORDER BY received_at, id
LIMIT :page_limit;

-- ============================================================================
-- Query Shape 4: Order depth snapshot
-- Targeted Index: order_depth_pk (tick_id, side, level)
-- Expected Plan: Index Scan using PK index, returning exactly 10 levels.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    tick_id, side, level, price, quantity, order_count
FROM market.order_depth
WHERE tick_id = :tick_id
ORDER BY side, level;

-- ============================================================================
-- Query Shape 5: Replay with complete depth snapshots
-- Design: Subquery/CTE limits ticks first to ensure exactly :page_limit complete
-- snapshots (e.g. 100 ticks produce exactly 1,000 depth rows, not 100 depth rows).
-- Determinism note: Ordering on tied timestamps is determined by (received_at, id),
-- which reflects deterministic storage order rather than exchange-time order.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS)
WITH page_ticks AS (
    SELECT
        id, instrument_id, sequence, received_at, last_price, volume
    FROM market.live_ticks
    WHERE received_at >= :start_time
      AND (received_at, id) > (:cursor_time, :cursor_id)
      AND received_at < :end_time
    ORDER BY received_at, id
    LIMIT :page_limit
)
SELECT
    pt.id AS tick_id,
    pt.instrument_id,
    pt.received_at,
    pt.last_price,
    pt.volume,
    od.side,
    od.level,
    od.price AS depth_price,
    od.quantity AS depth_quantity,
    od.order_count AS depth_order_count
FROM page_ticks pt
JOIN market.order_depth od ON od.tick_id = pt.id
ORDER BY pt.received_at, pt.id, od.side, od.level;
