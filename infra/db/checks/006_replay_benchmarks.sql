-- Replay and Database Performance Benchmarks (Task 004)
--
-- Execution instructions:
--   psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/006_replay_benchmarks.sql
--
-- Parameter override examples:
--   psql -v ON_ERROR_STOP=1 -d intraday_streaming \
--     -v stream_id="'c0000000-0000-0000-0000-000000000003'" \
--     -v instrument_id=83 \
--     -v page_limit_small=100 \
--     -v page_limit_large=1000 \
--     -f infra/db/checks/006_replay_benchmarks.sql

\set ON_ERROR_STOP on

-- Guard: Ensure execution only against the intended database
DO $$
BEGIN
    IF current_database() <> 'intraday_streaming' THEN
        RAISE EXCEPTION 'Refusing benchmarks: expected database "intraday_streaming", connected to "%"', current_database();
    END IF;
END $$;

-- Parameters with fallback defaults
\if :{?stream_id}
\else
\set stream_id '''c0000000-0000-0000-0000-000000000003'''
\endif

\if :{?instrument_id}
\else
\set instrument_id 83
\endif

\if :{?start_time}
\else
\set start_time '''2026-10-09 09:15:00+05:30'''
\endif

\if :{?end_time}
\else
\set end_time '''2026-10-09 09:31:40+05:30'''
\endif

\if :{?page_limit_small}
\else
\set page_limit_small 100
\endif

\if :{?page_limit_large}
\else
\set page_limit_large 1000
\endif

-- Cursor checkpoints for first, middle, and late pages
\if :{?cursor_first_time}
\else
\set cursor_first_time :start_time
\endif

\if :{?cursor_first_id}
\else
\set cursor_first_id 0
\endif

\if :{?cursor_mid_time}
\else
\set cursor_mid_time '''2026-10-09 09:23:00+05:30'''
\endif

\if :{?cursor_mid_id}
\else
\set cursor_mid_id 150000
\endif

\if :{?cursor_late_time}
\else
\set cursor_late_time '''2026-10-09 09:30:00+05:30'''
\endif

\if :{?cursor_late_id}
\else
\set cursor_late_id 190000
\endif

\echo '============================================================'
\echo 'TASK 004: PARAMETERIZED DATABASE PERFORMANCE BENCHMARKS'
\echo '  stream_id          : ' :stream_id
\echo '  instrument_id      : ' :instrument_id
\echo '  start_time         : ' :start_time
\echo '  end_time           : ' :end_time
\echo '  page_limit_small   : ' :page_limit_small
\echo '  page_limit_large   : ' :page_limit_large
\echo '============================================================'

-- ----------------------------------------------------------------------------
-- Test 1: Latest tick per instrument
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- [1/8] Latest Tick for Single Instrument ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    t.id, t.instrument_id, t.stream_id, t.sequence,
    t.received_at, t.exchange_at, t.last_trade_at,
    t.last_price, t.average_price, t.open_price, t.high_price, t.low_price, t.close_price,
    t.last_quantity, t.volume, t.total_buy_quantity, t.total_sell_quantity,
    t.open_interest, t.open_interest_high, t.open_interest_low,
    inst.instrument_token, inst.trading_symbol
FROM market.live_ticks t
JOIN feed.instruments inst ON inst.id = t.instrument_id
WHERE t.instrument_id = :instrument_id
ORDER BY t.received_at DESC, t.id DESC
LIMIT 1;

-- ----------------------------------------------------------------------------
-- Test 2: Instrument historical slice (bounded time window)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- [2/8] Instrument History Slice ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    t.id, t.instrument_id, t.sequence, t.received_at, t.exchange_at,
    t.last_price, t.volume, t.open_interest,
    inst.instrument_token, inst.trading_symbol
FROM market.live_ticks t
JOIN feed.instruments inst ON inst.id = t.instrument_id
WHERE t.instrument_id = :instrument_id
  AND t.received_at >= :start_time
  AND t.received_at < :end_time
ORDER BY t.received_at ASC, t.id ASC
LIMIT :page_limit_small;

-- ----------------------------------------------------------------------------
-- Test 3: Replay First Page - Small Page (:page_limit_small)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- [3/8] Keyset Replay: First Page (Small Page Size) ---'
EXPLAIN (ANALYZE, BUFFERS)
WITH page_ticks AS (
    SELECT
        t.id, t.instrument_id, t.stream_id, t.sequence,
        t.received_at, t.exchange_at, t.last_trade_at,
        t.last_price, t.average_price, t.open_price, t.high_price, t.low_price, t.close_price,
        t.last_quantity, t.volume, t.total_buy_quantity, t.total_sell_quantity,
        t.open_interest, t.open_interest_high, t.open_interest_low,
        inst.instrument_token, inst.trading_symbol
    FROM market.live_ticks t
    JOIN feed.instruments inst ON inst.id = t.instrument_id
    WHERE t.stream_id = :stream_id
      AND t.received_at >= :start_time
      AND (t.received_at, t.id) > (:cursor_first_time, :cursor_first_id)
      AND t.received_at < :end_time
    ORDER BY t.received_at ASC, t.id ASC
    LIMIT :page_limit_small
)
SELECT
    pt.*,
    od.side, od.level, od.price AS depth_price, od.quantity AS depth_quantity, od.order_count AS depth_order_count
FROM page_ticks pt
JOIN market.order_depth od ON od.tick_id = pt.id
ORDER BY pt.received_at ASC, pt.id ASC, od.side ASC, od.level ASC;

-- ----------------------------------------------------------------------------
-- Test 4: Replay First Page - Large Page (:page_limit_large)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- [4/8] Keyset Replay: First Page (Large Page Size) ---'
EXPLAIN (ANALYZE, BUFFERS)
WITH page_ticks AS (
    SELECT
        t.id, t.instrument_id, t.stream_id, t.sequence,
        t.received_at, t.exchange_at, t.last_trade_at,
        t.last_price, t.average_price, t.open_price, t.high_price, t.low_price, t.close_price,
        t.last_quantity, t.volume, t.total_buy_quantity, t.total_sell_quantity,
        t.open_interest, t.open_interest_high, t.open_interest_low,
        inst.instrument_token, inst.trading_symbol
    FROM market.live_ticks t
    JOIN feed.instruments inst ON inst.id = t.instrument_id
    WHERE t.stream_id = :stream_id
      AND t.received_at >= :start_time
      AND (t.received_at, t.id) > (:cursor_first_time, :cursor_first_id)
      AND t.received_at < :end_time
    ORDER BY t.received_at ASC, t.id ASC
    LIMIT :page_limit_large
)
SELECT
    pt.*,
    od.side, od.level, od.price AS depth_price, od.quantity AS depth_quantity, od.order_count AS depth_order_count
FROM page_ticks pt
JOIN market.order_depth od ON od.tick_id = pt.id
ORDER BY pt.received_at ASC, pt.id ASC, od.side ASC, od.level ASC;

-- ----------------------------------------------------------------------------
-- Test 5: Replay Middle Page - Large Page (:page_limit_large)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- [5/8] Keyset Replay: Middle Page (Large Page Size) ---'
EXPLAIN (ANALYZE, BUFFERS)
WITH page_ticks AS (
    SELECT
        t.id, t.instrument_id, t.stream_id, t.sequence,
        t.received_at, t.exchange_at, t.last_trade_at,
        t.last_price, t.average_price, t.open_price, t.high_price, t.low_price, t.close_price,
        t.last_quantity, t.volume, t.total_buy_quantity, t.total_sell_quantity,
        t.open_interest, t.open_interest_high, t.open_interest_low,
        inst.instrument_token, inst.trading_symbol
    FROM market.live_ticks t
    JOIN feed.instruments inst ON inst.id = t.instrument_id
    WHERE t.stream_id = :stream_id
      AND t.received_at >= :start_time
      AND (t.received_at, t.id) > (:cursor_mid_time, :cursor_mid_id)
      AND t.received_at < :end_time
    ORDER BY t.received_at ASC, t.id ASC
    LIMIT :page_limit_large
)
SELECT
    pt.*,
    od.side, od.level, od.price AS depth_price, od.quantity AS depth_quantity, od.order_count AS depth_order_count
FROM page_ticks pt
JOIN market.order_depth od ON od.tick_id = pt.id
ORDER BY pt.received_at ASC, pt.id ASC, od.side ASC, od.level ASC;

-- ----------------------------------------------------------------------------
-- Test 6: Replay Late Page - Large Page (:page_limit_large)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- [6/8] Keyset Replay: Late Page (Large Page Size) ---'
EXPLAIN (ANALYZE, BUFFERS)
WITH page_ticks AS (
    SELECT
        t.id, t.instrument_id, t.stream_id, t.sequence,
        t.received_at, t.exchange_at, t.last_trade_at,
        t.last_price, t.average_price, t.open_price, t.high_price, t.low_price, t.close_price,
        t.last_quantity, t.volume, t.total_buy_quantity, t.total_sell_quantity,
        t.open_interest, t.open_interest_high, t.open_interest_low,
        inst.instrument_token, inst.trading_symbol
    FROM market.live_ticks t
    JOIN feed.instruments inst ON inst.id = t.instrument_id
    WHERE t.stream_id = :stream_id
      AND t.received_at >= :start_time
      AND (t.received_at, t.id) > (:cursor_late_time, :cursor_late_id)
      AND t.received_at < :end_time
    ORDER BY t.received_at ASC, t.id ASC
    LIMIT :page_limit_large
)
SELECT
    pt.*,
    od.side, od.level, od.price AS depth_price, od.quantity AS depth_quantity, od.order_count AS depth_order_count
FROM page_ticks pt
JOIN market.order_depth od ON od.tick_id = pt.id
ORDER BY pt.received_at ASC, pt.id ASC, od.side ASC, od.level ASC;

-- ----------------------------------------------------------------------------
-- Test 7: Replay with Narrow Subscription Subset - Small Page (:page_limit_small)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- [7/8] Keyset Replay: Narrow Subscription Subset (Small Page Size) ---'
EXPLAIN (ANALYZE, BUFFERS)
WITH page_ticks AS (
    SELECT
        t.id, t.instrument_id, t.stream_id, t.sequence,
        t.received_at, t.exchange_at, t.last_trade_at,
        t.last_price, t.average_price, t.open_price, t.high_price, t.low_price, t.close_price,
        t.last_quantity, t.volume, t.total_buy_quantity, t.total_sell_quantity,
        t.open_interest, t.open_interest_high, t.open_interest_low,
        inst.instrument_token, inst.trading_symbol
    FROM market.live_ticks t
    JOIN feed.instruments inst ON inst.id = t.instrument_id
    WHERE t.stream_id = :stream_id
      AND t.instrument_id = ANY(ARRAY[83, 84]::bigint[])
      AND t.received_at >= :start_time
      AND (t.received_at, t.id) > (:cursor_first_time, :cursor_first_id)
      AND t.received_at < :end_time
    ORDER BY t.received_at ASC, t.id ASC
    LIMIT :page_limit_small
)
SELECT
    pt.*,
    od.side, od.level, od.price AS depth_price, od.quantity AS depth_quantity, od.order_count AS depth_order_count
FROM page_ticks pt
JOIN market.order_depth od ON od.tick_id = pt.id
ORDER BY pt.received_at ASC, pt.id ASC, od.side ASC, od.level ASC;

-- ----------------------------------------------------------------------------
-- Test 8: Replay with Narrow Subscription Subset - Large Page (:page_limit_large)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- [8/8] Keyset Replay: Narrow Subscription Subset (Large Page Size) ---'
EXPLAIN (ANALYZE, BUFFERS)
WITH page_ticks AS (
    SELECT
        t.id, t.instrument_id, t.stream_id, t.sequence,
        t.received_at, t.exchange_at, t.last_trade_at,
        t.last_price, t.average_price, t.open_price, t.high_price, t.low_price, t.close_price,
        t.last_quantity, t.volume, t.total_buy_quantity, t.total_sell_quantity,
        t.open_interest, t.open_interest_high, t.open_interest_low,
        inst.instrument_token, inst.trading_symbol
    FROM market.live_ticks t
    JOIN feed.instruments inst ON inst.id = t.instrument_id
    WHERE t.stream_id = :stream_id
      AND t.instrument_id = ANY(ARRAY[83, 84]::bigint[])
      AND t.received_at >= :start_time
      AND (t.received_at, t.id) > (:cursor_first_time, :cursor_first_id)
      AND t.received_at < :end_time
    ORDER BY t.received_at ASC, t.id ASC
    LIMIT :page_limit_large
)
SELECT
    pt.*,
    od.side, od.level, od.price AS depth_price, od.quantity AS depth_quantity, od.order_count AS depth_order_count
FROM page_ticks pt
JOIN market.order_depth od ON od.tick_id = pt.id
ORDER BY pt.received_at ASC, pt.id ASC, od.side ASC, od.level ASC;
