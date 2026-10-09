-- Verification Check 005: Runtime role (streaming_app) permissions on market schema
--
-- Execution instructions:
--   env $(grep -v '^#' .env.local | xargs) psql -v ON_ERROR_STOP=1 -f infra/db/checks/005_verify_market_runtime_permissions.sql
--
-- Verification goals:
--   - Connected database is strictly intraday_streaming.
--   - Connected user is strictly streaming_app.
--   - streaming_app has no USAGE or CREATE privileges on public schema.
--   - streaming_app has USAGE on schema market and SELECT on market.live_ticks and market.order_depth.
--   - streaming_app CANNOT insert, update, or delete in market tables.
--   - streaming_app CANNOT create tables in market or public.

\set ON_ERROR_STOP on

BEGIN;

-- Guard: Ensure execution only against the intended database
DO $$
BEGIN
    IF current_database() <> 'intraday_streaming' THEN
        RAISE EXCEPTION 'Refusing checks: expected database "intraday_streaming", connected to "%"', current_database();
    END IF;
END $$;

-- Check 1: Explicitly assert current_user = 'streaming_app'
DO $$
BEGIN
    IF current_user <> 'streaming_app' THEN
        RAISE EXCEPTION 'Expected current_user to be "streaming_app", but connected as "%"', current_user;
    END IF;
    RAISE NOTICE 'CHECK 1 PASS: Verified connected as role "streaming_app"';
END $$;

-- Check 2: Explicitly assert denied public schema privileges
DO $$
BEGIN
    IF has_schema_privilege('streaming_app', 'public', 'USAGE') THEN
        RAISE EXCEPTION 'FAIL: streaming_app unexpectedly has USAGE privilege on public schema';
    END IF;

    IF has_schema_privilege('streaming_app', 'public', 'CREATE') THEN
        RAISE EXCEPTION 'FAIL: streaming_app unexpectedly has CREATE privilege on public schema';
    END IF;

    RAISE NOTICE 'CHECK 2 PASS: Verified public schema USAGE and CREATE are denied to streaming_app';
END $$;

-- Check 3: Explicitly assert market schema USAGE and table SELECT privileges
DO $$
BEGIN
    IF NOT has_schema_privilege('streaming_app', 'market', 'USAGE') THEN
        RAISE EXCEPTION 'FAIL: streaming_app lacks USAGE privilege on schema market';
    END IF;

    IF NOT has_table_privilege('streaming_app', 'market.live_ticks', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: streaming_app lacks SELECT privilege on market.live_ticks';
    END IF;

    IF NOT has_table_privilege('streaming_app', 'market.order_depth', 'SELECT') THEN
        RAISE EXCEPTION 'FAIL: streaming_app lacks SELECT privilege on market.order_depth';
    END IF;

    RAISE NOTICE 'CHECK 3 PASS: Verified USAGE on market and SELECT on market tables granted to streaming_app';
END $$;

-- Check 4: Verify SELECT queries execute cleanly under streaming_app
SELECT count(*) AS live_ticks_read_count FROM market.live_ticks;
SELECT count(*) AS order_depth_read_count FROM market.order_depth;

-- Check 5: Verify all write and DDL operations on market tables are denied
DO $$
DECLARE
    caught boolean;
BEGIN
    -- 5a: INSERT market.live_ticks denied
    caught := false;
    BEGIN
        INSERT INTO market.live_ticks (
            instrument_id, stream_id, sequence, received_at,
            last_price, average_price, open_price, high_price, low_price, close_price,
            last_quantity, volume, total_buy_quantity, total_sell_quantity,
            open_interest, open_interest_high, open_interest_low
        ) VALUES (
            1, '00000000-0000-0000-0000-000000000000'::uuid, 1, now(),
            100, 100, 100, 100, 100, 100, 1, 1, 1, 1, 0, 0, 0
        );
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: INSERT on market.live_ticks was permitted'; END IF;

    -- 5b: UPDATE market.live_ticks denied
    caught := false;
    BEGIN
        UPDATE market.live_ticks SET last_price = 99999 WHERE id = 1;
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: UPDATE on market.live_ticks was permitted'; END IF;

    -- 5c: DELETE market.live_ticks denied
    caught := false;
    BEGIN
        DELETE FROM market.live_ticks WHERE id = 1;
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: DELETE on market.live_ticks was permitted'; END IF;

    -- 5d: INSERT market.order_depth denied
    caught := false;
    BEGIN
        INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
        VALUES (1, 'bid', 1, 100, 10, 1);
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: INSERT on market.order_depth was permitted'; END IF;

    -- 5e: UPDATE market.order_depth denied
    caught := false;
    BEGIN
        UPDATE market.order_depth SET price = 99999 WHERE tick_id = 1;
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: UPDATE on market.order_depth was permitted'; END IF;

    -- 5f: DELETE market.order_depth denied
    caught := false;
    BEGIN
        DELETE FROM market.order_depth WHERE tick_id = 1;
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: DELETE on market.order_depth was permitted'; END IF;

    -- 5g: CREATE TABLE in market denied
    caught := false;
    BEGIN
        EXECUTE 'CREATE TABLE market.forbidden (id int)';
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: CREATE TABLE in market was permitted'; END IF;

    -- 5h: CREATE TABLE in public denied
    caught := false;
    BEGIN
        EXECUTE 'CREATE TABLE public.forbidden (id int)';
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: CREATE TABLE in public was permitted'; END IF;

    RAISE NOTICE 'CHECK 5 PASS: All unauthorized mutation and DDL attempts on market correctly rejected';
END $$;

ROLLBACK;
