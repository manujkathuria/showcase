-- Verification Check 003: Market tick and order depth constraints and query shapes
--
-- Execution instructions:
--   psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/003_market_tick_storage_checks.sql
--
-- Behavior:
--   - Tests schema authorization, table ownership, constraint enforcement, and query shapes.
--   - All test fixtures (instruments, ticks, depth) are created and validated entirely within
--     a transaction that ends in ROLLBACK, ensuring 100% isolation from existing or future seeded data.

\set ON_ERROR_STOP on

BEGIN;

-- Guard: Ensure execution only against the intended database
DO $$
BEGIN
    IF current_database() <> 'intraday_streaming' THEN
        RAISE EXCEPTION 'Refusing checks: expected database "intraday_streaming", connected to "%"', current_database();
    END IF;
END $$;

-- Check 1: Verify schema authorization and table ownership
DO $$
DECLARE
    v_schema_owner text;
    v_ticks_owner text;
    v_depth_owner text;
    v_pub_ticks int;
    v_pub_depth int;
BEGIN
    SELECT r.rolname INTO v_schema_owner
    FROM pg_namespace n
    JOIN pg_roles r ON r.oid = n.nspowner
    WHERE n.nspname = 'market';

    IF v_schema_owner IS NULL THEN
        RAISE EXCEPTION 'Schema "market" does not exist';
    ELSIF v_schema_owner <> 'streaming_owner' THEN
        RAISE EXCEPTION 'Schema "market" is owned by % instead of streaming_owner', v_schema_owner;
    END IF;

    SELECT tableowner INTO v_ticks_owner
    FROM pg_tables
    WHERE schemaname = 'market' AND tablename = 'live_ticks';

    IF v_ticks_owner IS NULL THEN
        RAISE EXCEPTION 'Table "market.live_ticks" does not exist';
    ELSIF v_ticks_owner <> 'streaming_owner' THEN
        RAISE EXCEPTION 'Table "market.live_ticks" is owned by % instead of streaming_owner', v_ticks_owner;
    END IF;

    SELECT tableowner INTO v_depth_owner
    FROM pg_tables
    WHERE schemaname = 'market' AND tablename = 'order_depth';

    IF v_depth_owner IS NULL THEN
        RAISE EXCEPTION 'Table "market.order_depth" does not exist';
    ELSIF v_depth_owner <> 'streaming_owner' THEN
        RAISE EXCEPTION 'Table "market.order_depth" is owned by % instead of streaming_owner', v_depth_owner;
    END IF;

    SELECT count(*) INTO v_pub_ticks FROM pg_tables WHERE schemaname = 'public' AND tablename = 'live_ticks';
    SELECT count(*) INTO v_pub_depth FROM pg_tables WHERE schemaname = 'public' AND tablename = 'order_depth';
    IF v_pub_ticks > 0 OR v_pub_depth > 0 THEN
        RAISE EXCEPTION 'Market tables unexpectedly exist in public schema';
    END IF;

    RAISE NOTICE 'CHECK 1 PASS: Schema and tables exist in market and are owned by streaming_owner';
END $$;

-- Check 2: Constraint enforcement testing using isolated temporary fixtures
DO $$
DECLARE
    caught boolean;
    v_inst_id bigint;
    v_tick_id bigint;
    v_stream_id uuid := 'f0000000-0000-0000-0000-000000000001'::uuid;
    v_t1 timestamptz := '2026-10-09 09:15:00+05:30';
BEGIN
    -- Create isolated instrument for constraint checks
    INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type, expiry)
    VALUES (9999901, 'CHK', 'CHK_TEST_INST', 'CHK_SEG', 'EQ', NULL)
    RETURNING id INTO v_inst_id;

    -- 2a: Reject dangling instrument FK
    caught := false;
    BEGIN
        INSERT INTO market.live_ticks (
            instrument_id, stream_id, sequence, received_at,
            last_price, average_price, open_price, high_price, low_price, close_price,
            last_quantity, volume, total_buy_quantity, total_sell_quantity,
            open_interest, open_interest_high, open_interest_low
        ) VALUES (
            -999, v_stream_id, 1, v_t1,
            100, 100, 100, 100, 100, 100,
            1, 10, 100, 100,
            0, 0, 0
        );
    EXCEPTION WHEN foreign_key_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Dangling instrument_id was not rejected'; END IF;

    -- 2b: Reject sequence <= 0
    caught := false;
    BEGIN
        INSERT INTO market.live_ticks (
            instrument_id, stream_id, sequence, received_at,
            last_price, average_price, open_price, high_price, low_price, close_price,
            last_quantity, volume, total_buy_quantity, total_sell_quantity,
            open_interest, open_interest_high, open_interest_low
        ) VALUES (
            v_inst_id, v_stream_id, 0, v_t1,
            100, 100, 100, 100, 100, 100,
            1, 10, 100, 100,
            0, 0, 0
        );
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Sequence = 0 was not rejected'; END IF;

    -- 2c: Reject negative prices
    caught := false;
    BEGIN
        INSERT INTO market.live_ticks (
            instrument_id, stream_id, sequence, received_at,
            last_price, average_price, open_price, high_price, low_price, close_price,
            last_quantity, volume, total_buy_quantity, total_sell_quantity,
            open_interest, open_interest_high, open_interest_low
        ) VALUES (
            v_inst_id, v_stream_id, 1, v_t1,
            -1, 100, 100, 100, 100, 100,
            1, 10, 100, 100,
            0, 0, 0
        );
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Negative last_price was not rejected'; END IF;

    -- 2d: Reject negative quantities / volume
    caught := false;
    BEGIN
        INSERT INTO market.live_ticks (
            instrument_id, stream_id, sequence, received_at,
            last_price, average_price, open_price, high_price, low_price, close_price,
            last_quantity, volume, total_buy_quantity, total_sell_quantity,
            open_interest, open_interest_high, open_interest_low
        ) VALUES (
            v_inst_id, v_stream_id, 1, v_t1,
            100, 100, 100, 100, 100, 100,
            1, -5, 100, 100,
            0, 0, 0
        );
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Negative volume was not rejected'; END IF;

    -- 2e: Reject negative open interest
    caught := false;
    BEGIN
        INSERT INTO market.live_ticks (
            instrument_id, stream_id, sequence, received_at,
            last_price, average_price, open_price, high_price, low_price, close_price,
            last_quantity, volume, total_buy_quantity, total_sell_quantity,
            open_interest, open_interest_high, open_interest_low
        ) VALUES (
            v_inst_id, v_stream_id, 1, v_t1,
            100, 100, 100, 100, 100, 100,
            1, 10, 100, 100,
            -10, 0, 0
        );
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Negative open_interest was not rejected'; END IF;

    -- 2f: Insert valid tick
    INSERT INTO market.live_ticks (
        instrument_id, stream_id, sequence, received_at,
        last_price, average_price, open_price, high_price, low_price, close_price,
        last_quantity, volume, total_buy_quantity, total_sell_quantity,
        open_interest, open_interest_high, open_interest_low
    ) VALUES (
        v_inst_id, v_stream_id, 1, v_t1,
        50000, 50000, 50000, 50500, 49800, 50000,
        10, 500, 5000, 4500,
        10000, 12000, 9500
    ) RETURNING id INTO v_tick_id;

    -- 2g: Reject duplicate (stream_id, sequence)
    caught := false;
    BEGIN
        INSERT INTO market.live_ticks (
            instrument_id, stream_id, sequence, received_at,
            last_price, average_price, open_price, high_price, low_price, close_price,
            last_quantity, volume, total_buy_quantity, total_sell_quantity,
            open_interest, open_interest_high, open_interest_low
        ) VALUES (
            v_inst_id, v_stream_id, 1, v_t1,
            50000, 50000, 50000, 50500, 49800, 50000,
            10, 500, 5000, 4500,
            10000, 12000, 9500
        );
    EXCEPTION WHEN unique_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Duplicate (stream_id, sequence) was not rejected'; END IF;

    -- 2h: Equal timestamps and repeated prices are VALID for distinct sequence
    INSERT INTO market.live_ticks (
        instrument_id, stream_id, sequence, received_at,
        last_price, average_price, open_price, high_price, low_price, close_price,
        last_quantity, volume, total_buy_quantity, total_sell_quantity,
        open_interest, open_interest_high, open_interest_low
    ) VALUES (
        v_inst_id, v_stream_id, 2, v_t1,
        50000, 50000, 50000, 50500, 49800, 50000,
        10, 500, 5000, 4500,
        10000, 12000, 9500
    );

    -- 2i: Order depth - reject dangling tick FK
    caught := false;
    BEGIN
        INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
        VALUES (-999, 'bid', 1, 49990, 100, 5);
    EXCEPTION WHEN foreign_key_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Dangling tick_id in order_depth was not rejected'; END IF;

    -- 2j: Order depth - reject invalid side
    caught := false;
    BEGIN
        INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
        VALUES (v_tick_id, 'mid', 1, 49990, 100, 5);
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Invalid side was not rejected'; END IF;

    -- 2k: Order depth - reject invalid level (< 1 or > 5)
    caught := false;
    BEGIN
        INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
        VALUES (v_tick_id, 'bid', 0, 49990, 100, 5);
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Level 0 was not rejected'; END IF;

    caught := false;
    BEGIN
        INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
        VALUES (v_tick_id, 'bid', 6, 49990, 100, 5);
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Level 6 was not rejected'; END IF;

    -- 2l: Order depth - reject negative values
    caught := false;
    BEGIN
        INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
        VALUES (v_tick_id, 'bid', 1, -10, 100, 5);
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Negative depth price was not rejected'; END IF;

    -- 2m: Order depth - insert valid level and reject duplicate (tick_id, side, level)
    INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
    VALUES (v_tick_id, 'bid', 1, 49990, 100, 5);

    caught := false;
    BEGIN
        INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
        VALUES (v_tick_id, 'bid', 1, 49980, 200, 8);
    EXCEPTION WHEN unique_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Duplicate depth (tick_id, side, level) was not rejected'; END IF;

    -- Clean up Check 2 test rows so Check 3 runs against isolated dedicated fixtures
    DELETE FROM market.order_depth WHERE tick_id = v_tick_id;
    DELETE FROM market.live_ticks WHERE stream_id = v_stream_id;
    DELETE FROM feed.instruments WHERE id = v_inst_id;

    RAISE NOTICE 'CHECK 2 PASS: All table constraint tests passed';
END $$;

-- Check 3: Query shapes verification with isolated dedicated fixtures and exact identity assertions
DO $$
DECLARE
    v_inst_1 bigint;
    v_inst_2 bigint;
    v_stream uuid := 'f0000000-0000-0000-0000-000000000002'::uuid;
    t1_id bigint; t2_id bigint; t3_id bigint; t4_id bigint;
    r RECORD;
    v_count int;
    v_actual_ids bigint[];
    v_cursor_time timestamptz;
    v_cursor_id bigint;
    v_depth_row RECORD;
    v_expected_bids bigint[] := ARRAY[99, 98, 97, 96, 95];
    v_expected_asks bigint[] := ARRAY[101, 102, 103, 104, 105];
    v_level_idx int;
BEGIN
    -- Create dedicated instruments for query tests (one disabled, one without subscription)
    -- to assert independence from feed.subscriptions configuration
    INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type, expiry)
    VALUES (9999911, 'CHK', 'CHK_FEED_IND_1', 'CHK_SEG', 'EQ', NULL)
    RETURNING id INTO v_inst_1;

    INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type, expiry)
    VALUES (9999912, 'CHK', 'CHK_FEED_IND_2', 'CHK_SEG', 'FUT', '2026-12-31')
    RETURNING id INTO v_inst_2;

    -- Deliberately create a disabled subscription for inst_1 and no subscription for inst_2
    -- to prove market tick storage queries are decoupled from enabled feed configuration
    INSERT INTO feed.subscriptions (instrument_id, mode, enabled)
    VALUES (v_inst_1, 'full', false);

    -- Create 4 test ticks:
    -- t1: inst_1 at 09:15:00.000 (sequence 101, price 100)
    -- t2: inst_1 at 09:15:01.000 (sequence 102, price 101) - tied timestamp with t3
    -- t3: inst_2 at 09:15:01.000 (sequence 103, price 200) - tied timestamp with t2
    -- t4: inst_1 at 09:15:02.000 (sequence 104, price 102) - latest for inst_1
    INSERT INTO market.live_ticks (
        instrument_id, stream_id, sequence, received_at,
        last_price, average_price, open_price, high_price, low_price, close_price,
        last_quantity, volume, total_buy_quantity, total_sell_quantity,
        open_interest, open_interest_high, open_interest_low
    ) VALUES
        (v_inst_1, v_stream, 101, '2026-10-09 09:15:00+05:30', 100, 100, 100, 100, 100, 100, 1, 1, 1, 1, 0, 0, 0)
        RETURNING id INTO t1_id;

    INSERT INTO market.live_ticks (
        instrument_id, stream_id, sequence, received_at,
        last_price, average_price, open_price, high_price, low_price, close_price,
        last_quantity, volume, total_buy_quantity, total_sell_quantity,
        open_interest, open_interest_high, open_interest_low
    ) VALUES
        (v_inst_1, v_stream, 102, '2026-10-09 09:15:01+05:30', 101, 101, 100, 101, 100, 100, 2, 3, 2, 2, 0, 0, 0)
        RETURNING id INTO t2_id;

    INSERT INTO market.live_ticks (
        instrument_id, stream_id, sequence, received_at,
        last_price, average_price, open_price, high_price, low_price, close_price,
        last_quantity, volume, total_buy_quantity, total_sell_quantity,
        open_interest, open_interest_high, open_interest_low
    ) VALUES
        (v_inst_2, v_stream, 103, '2026-10-09 09:15:01+05:30', 200, 200, 200, 200, 200, 200, 5, 5, 5, 5, 0, 0, 0)
        RETURNING id INTO t3_id;

    INSERT INTO market.live_ticks (
        instrument_id, stream_id, sequence, received_at,
        last_price, average_price, open_price, high_price, low_price, close_price,
        last_quantity, volume, total_buy_quantity, total_sell_quantity,
        open_interest, open_interest_high, open_interest_low
    ) VALUES
        (v_inst_1, v_stream, 104, '2026-10-09 09:15:02+05:30', 102, 102, 100, 102, 100, 100, 1, 4, 3, 3, 0, 0, 0)
        RETURNING id INTO t4_id;

    -- Insert exactly 10 depth levels for each of the 4 ticks
    INSERT INTO market.order_depth (tick_id, side, level, price, quantity, order_count)
    SELECT
        t.id, d.side, d.level,
        t.last_price + CASE WHEN d.side = 'bid' THEN -d.level ELSE d.level END,
        10 * d.level, d.level
    FROM market.live_ticks t
    CROSS JOIN (
        VALUES
            ('bid'::text, 1::smallint), ('bid', 2), ('bid', 3), ('bid', 4), ('bid', 5),
            ('ask'::text, 1::smallint), ('ask', 2), ('ask', 3), ('ask', 4), ('ask', 5)
    ) AS d(side, level)
    WHERE t.id IN (t1_id, t2_id, t3_id, t4_id);

    -- 3a: Query 1: Latest tick per instrument
    SELECT id, sequence, last_price, received_at
    INTO r
    FROM market.live_ticks
    WHERE instrument_id = v_inst_1
    ORDER BY received_at DESC, id DESC
    LIMIT 1;

    IF r.id <> t4_id OR r.sequence <> 104 OR r.last_price <> 102 THEN
        RAISE EXCEPTION 'Latest tick assertion failed: got (id=%, seq=%, price=%), expected (id=%, seq=104, price=102)',
            r.id, r.sequence, r.last_price, t4_id;
    END IF;

    -- 3b: Query 2: Instrument history in half-open range [09:15:00, 09:15:02)
    -- Must return exactly [t1_id, t2_id] in strict ascending order, excluding t3 (diff inst) and t4 (at upper bound 09:15:02)
    v_actual_ids := ARRAY[]::bigint[];
    FOR r IN
        SELECT id FROM market.live_ticks
        WHERE instrument_id = v_inst_1
          AND received_at >= '2026-10-09 09:15:00+05:30'
          AND received_at < '2026-10-09 09:15:02+05:30'
        ORDER BY received_at, id
        LIMIT 10
    LOOP
        v_actual_ids := array_append(v_actual_ids, r.id);
    END LOOP;

    IF v_actual_ids <> ARRAY[t1_id, t2_id] THEN
        RAISE EXCEPTION 'History range assertion failed: got %, expected %', v_actual_ids, ARRAY[t1_id, t2_id];
    END IF;

    -- 3c: Query 3: Replay with keyset pagination across tied timestamps
    -- Page 1: range [09:15:00, 09:15:03), limit 2
    v_actual_ids := ARRAY[]::bigint[];
    FOR r IN
        SELECT received_at, id
        FROM market.live_ticks
        WHERE stream_id = v_stream
          AND received_at >= '2026-10-09 09:15:00+05:30'
          AND received_at < '2026-10-09 09:15:03+05:30'
        ORDER BY received_at, id
        LIMIT 2
    LOOP
        v_actual_ids := array_append(v_actual_ids, r.id);
        v_cursor_time := r.received_at;
        v_cursor_id := r.id;
    END LOOP;

    IF v_actual_ids <> ARRAY[t1_id, t2_id] THEN
        RAISE EXCEPTION 'Keyset Page 1 mismatch: got %, expected %', v_actual_ids, ARRAY[t1_id, t2_id];
    END IF;

    -- Page 2: with cursor (received_at, id) > (v_cursor_time, v_cursor_id) and lower bound
    v_actual_ids := ARRAY[]::bigint[];
    FOR r IN
        SELECT id
        FROM market.live_ticks
        WHERE stream_id = v_stream
          AND received_at >= '2026-10-09 09:15:00+05:30'
          AND (received_at, id) > (v_cursor_time, v_cursor_id)
          AND received_at < '2026-10-09 09:15:03+05:30'
        ORDER BY received_at, id
        LIMIT 2
    LOOP
        v_actual_ids := array_append(v_actual_ids, r.id);
    END LOOP;

    -- Must return exactly [t3_id, t4_id], proving deterministic tie-breaking on tied timestamp (09:15:01)
    IF v_actual_ids <> ARRAY[t3_id, t4_id] THEN
        RAISE EXCEPTION 'Keyset Page 2 mismatch: got %, expected %', v_actual_ids, ARRAY[t3_id, t4_id];
    END IF;

    -- 3d: Query 4: Order depth snapshot completeness & level order
    -- Assert every single returned level for t1 (5 bids descending, 5 asks ascending)
    v_count := 0;
    FOR v_depth_row IN
        SELECT side, level, price, quantity, order_count
        FROM market.order_depth
        WHERE tick_id = t1_id
        ORDER BY side, level
    LOOP
        v_count := v_count + 1;
        IF v_depth_row.side = 'ask' THEN
            v_level_idx := v_depth_row.level;
            IF v_depth_row.price <> v_expected_asks[v_level_idx] THEN
                RAISE EXCEPTION 'Depth ask level % price mismatch: got %, expected %',
                    v_level_idx, v_depth_row.price, v_expected_asks[v_level_idx];
            END IF;
        ELSIF v_depth_row.side = 'bid' THEN
            v_level_idx := v_depth_row.level;
            IF v_depth_row.price <> v_expected_bids[v_level_idx] THEN
                RAISE EXCEPTION 'Depth bid level % price mismatch: got %, expected %',
                    v_level_idx, v_depth_row.price, v_expected_bids[v_level_idx];
            END IF;
        END IF;
    END LOOP;

    IF v_count <> 10 THEN
        RAISE EXCEPTION 'Depth snapshot count for tick % is %, expected exactly 10', t1_id, v_count;
    END IF;

    -- Also verify completeness for all other 3 ticks (10 levels each)
    FOR r IN SELECT id FROM market.live_ticks WHERE id IN (t2_id, t3_id, t4_id) LOOP
        SELECT count(*) INTO v_count FROM market.order_depth WHERE tick_id = r.id;
        IF v_count <> 10 THEN
            RAISE EXCEPTION 'Depth snapshot completeness failed for tick %: got % levels', r.id, v_count;
        END IF;
    END LOOP;

    -- 3e: Query 5: Replay with depth (subquery/CTE limits ticks first, then joins depth)
    -- Page of 2 ticks produces exactly 20 depth rows, with strictly ordered tick IDs and levels
    v_actual_ids := ARRAY[]::bigint[];
    v_count := 0;
    FOR r IN
        WITH page_ticks AS (
            SELECT id, instrument_id, received_at, last_price
            FROM market.live_ticks
            WHERE stream_id = v_stream
              AND received_at >= '2026-10-09 09:15:00+05:30'
              AND received_at < '2026-10-09 09:15:03+05:30'
            ORDER BY received_at, id
            LIMIT 2
        )
        SELECT pt.id AS tick_id, od.side, od.level
        FROM page_ticks pt
        JOIN market.order_depth od ON od.tick_id = pt.id
        ORDER BY pt.received_at, pt.id, od.side, od.level
    LOOP
        v_count := v_count + 1;
        IF NOT (r.tick_id = ANY(v_actual_ids)) THEN
            v_actual_ids := array_append(v_actual_ids, r.tick_id);
        END IF;
    END LOOP;

    IF v_actual_ids <> ARRAY[t1_id, t2_id] OR v_count <> 20 THEN
        RAISE EXCEPTION 'Replay with depth assertion failed: got tick IDs %, total depth rows % (expected % and 20)',
            v_actual_ids, v_count, ARRAY[t1_id, t2_id];
    END IF;

    RAISE NOTICE 'CHECK 3 PASS: All five query shapes validated with exact expected identities and snapshot completeness';
END $$;

ROLLBACK;
