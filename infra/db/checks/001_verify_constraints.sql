-- Verification Check 001: Constraint, ownership, and startup query verification
--
-- Execution instructions:
--   Run as an authorized administrator:
--     psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/checks/001_verify_constraints.sql
--
-- Behavior:
--   Tests table existence, ownership, constraints, foreign keys, and query semantics.
--   All temporary test insertions are performed within a transaction that ends with ROLLBACK.
--   Leaves no residual rows or schema objects behind.

\set ON_ERROR_STOP on

BEGIN;

-- Guard: Ensure execution only against the intended database
DO $$
BEGIN
    IF current_database() <> 'intraday_streaming' THEN
        RAISE EXCEPTION 'Refusing checks: expected database "intraday_streaming", connected to "%"', current_database();
    END IF;
END $$;

-- Check 1: Verify tables exist in 'feed' schema and are owned by 'streaming_owner'
DO $$
DECLARE
    inst_owner text;
    subs_owner text;
    pub_inst_count int;
    pub_subs_count int;
BEGIN
    SELECT tableowner INTO inst_owner
    FROM pg_tables
    WHERE schemaname = 'feed' AND tablename = 'instruments';

    IF inst_owner IS NULL THEN
        RAISE EXCEPTION 'feed.instruments table does not exist';
    ELSIF inst_owner <> 'streaming_owner' THEN
        RAISE EXCEPTION 'feed.instruments is owned by % instead of streaming_owner', inst_owner;
    END IF;

    SELECT tableowner INTO subs_owner
    FROM pg_tables
    WHERE schemaname = 'feed' AND tablename = 'subscriptions';

    IF subs_owner IS NULL THEN
        RAISE EXCEPTION 'feed.subscriptions table does not exist';
    ELSIF subs_owner <> 'streaming_owner' THEN
        RAISE EXCEPTION 'feed.subscriptions is owned by % instead of streaming_owner', subs_owner;
    END IF;

    SELECT count(*) INTO pub_inst_count
    FROM pg_tables
    WHERE schemaname = 'public' AND tablename = 'instruments';

    SELECT count(*) INTO pub_subs_count
    FROM pg_tables
    WHERE schemaname = 'public' AND tablename = 'subscriptions';

    IF pub_inst_count > 0 OR pub_subs_count > 0 THEN
        RAISE EXCEPTION 'Configuration tables exist in public schema unexpectedly';
    END IF;

    RAISE NOTICE 'CHECK 1 PASS: feed.instruments and feed.subscriptions exist in feed and are owned by streaming_owner';
END $$;

-- Check 2: Constraint enforcement testing
DO $$
DECLARE
    caught boolean;
    valid_id bigint;
    fut_id bigint;
BEGIN
    -- 2a: Reject token = 0
    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (0, 'TEST', 'SYM_0', 'SEG', 'EQ');
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Token 0 was not rejected by instruments_token_range'; END IF;

    -- 2b: Reject token > 4294967295
    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (4294967296, 'TEST', 'SYM_MAX', 'SEG', 'EQ');
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Token > 4294967295 was not rejected'; END IF;

    -- 2c: Reject empty / whitespace metadata
    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (10001, '   ', 'SYM_1', 'SEG', 'EQ');
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Empty exchange was not rejected'; END IF;

    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (10002, 'NSE', '', 'SEG', 'EQ');
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Empty trading_symbol was not rejected'; END IF;

    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (10003, 'NSE', 'SYM_3', ' ', 'EQ');
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Empty segment was not rejected'; END IF;

    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (10004, 'NSE', 'SYM_4', 'SEG', '  ');
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Empty instrument_type was not rejected'; END IF;

    -- 2d: Insert valid cash instrument with NULL expiry
    INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type, expiry)
    VALUES (10010, 'TEST_EX', 'TEST_CASH', 'TEST_SEG', 'EQ', NULL)
    RETURNING id INTO valid_id;

    -- 2e: Insert valid dated futures instrument with date expiry
    INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type, expiry)
    VALUES (10011, 'TEST_EX', 'TEST_FUT', 'TEST_SEG', 'FUT', '2026-12-31')
    RETURNING id INTO fut_id;

    -- 2f: Reject duplicate token
    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (10010, 'DIFF_EX', 'DIFF_SYM', 'TEST_SEG', 'EQ');
    EXCEPTION WHEN unique_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Duplicate instrument_token was not rejected'; END IF;

    -- 2g: Reject duplicate (exchange, trading_symbol)
    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (10020, 'TEST_EX', 'TEST_CASH', 'TEST_SEG', 'EQ');
    EXCEPTION WHEN unique_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Duplicate (exchange, trading_symbol) was not rejected'; END IF;

    -- 2h: Reject unknown instrument reference in feed.subscriptions
    caught := false;
    BEGIN
        INSERT INTO feed.subscriptions (instrument_id, mode, enabled)
        VALUES (-999, 'full', true);
    EXCEPTION WHEN foreign_key_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Non-existent instrument_id in subscriptions was not rejected'; END IF;

    -- 2i: Reject non-full mode
    caught := false;
    BEGIN
        INSERT INTO feed.subscriptions (instrument_id, mode, enabled)
        VALUES (valid_id, 'quote', true);
    EXCEPTION WHEN check_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Non-full mode was not rejected'; END IF;

    -- 2j: Insert valid subscription and reject duplicate subscription
    INSERT INTO feed.subscriptions (instrument_id, mode, enabled)
    VALUES (valid_id, 'full', true);

    caught := false;
    BEGIN
        INSERT INTO feed.subscriptions (instrument_id, mode, enabled)
        VALUES (valid_id, 'full', false);
    EXCEPTION WHEN unique_violation THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: Duplicate subscription for same instrument was not rejected'; END IF;

    -- Clean up temporary test rows before query check (entire transaction will also ROLLBACK)
    DELETE FROM feed.subscriptions WHERE instrument_id IN (valid_id, fut_id);
    DELETE FROM feed.instruments WHERE id IN (valid_id, fut_id);

    RAISE NOTICE 'CHECK 2 PASS: All constraint tests passed (duplicate tokens, duplicate symbols, token range, empty metadata, FK, PK, full mode)';
END $$;

-- Check 3: Query assertions and output
-- Explicitly asserts that the enabled-subscriptions query produces the exact expected rows in deterministic order.
DO $$
DECLARE
    r RECORD;
    row_count int := 0;
    expected_tokens bigint[] := ARRAY[9900001::bigint, 9900002::bigint];
    expected_modes text[] := ARRAY['full', 'full'];
BEGIN
    FOR r IN
        SELECT i.instrument_token, s.mode
        FROM feed.subscriptions AS s
        JOIN feed.instruments AS i ON i.id = s.instrument_id
        WHERE s.enabled
        ORDER BY i.instrument_token
    LOOP
        row_count := row_count + 1;
        IF row_count > array_length(expected_tokens, 1) THEN
            RAISE EXCEPTION 'Startup query returned more rows than expected (> %)', array_length(expected_tokens, 1);
        END IF;

        IF r.instrument_token <> expected_tokens[row_count] OR r.mode <> expected_modes[row_count] THEN
            RAISE EXCEPTION 'Startup query row % mismatch: got (token=%, mode=%), expected (token=%, mode=%)',
                row_count, r.instrument_token, r.mode, expected_tokens[row_count], expected_modes[row_count];
        END IF;
    END LOOP;

    IF row_count <> array_length(expected_tokens, 1) THEN
        RAISE EXCEPTION 'Startup query returned % rows, expected %', row_count, array_length(expected_tokens, 1);
    END IF;

    RAISE NOTICE 'CHECK 3 PASS: Startup query returns exact expected enabled subscriptions in deterministic order';
END $$;

SELECT i.instrument_token, s.mode
FROM feed.subscriptions AS s
JOIN feed.instruments AS i ON i.id = s.instrument_id
WHERE s.enabled
ORDER BY i.instrument_token;

-- Roll back all test rows inserted during this verification session
ROLLBACK;
