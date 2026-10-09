-- Verification Check 002: Runtime role (streaming_app) permissions check
--
-- Execution instructions:
--   Run using runtime credentials loaded from .env.local:
--     env $(grep -v '^#' .env.local | xargs) psql -v ON_ERROR_STOP=1 -f infra/db/checks/002_verify_runtime_permissions.sql
--
-- Verification goals:
--   - Connected database is strictly intraday_streaming.
--   - Connected user is strictly streaming_app.
--   - streaming_app has no USAGE or CREATE privileges on public schema.
--   - streaming_app can execute the startup query on feed configuration tables, returning exact expected rows.
--   - streaming_app CANNOT insert, update, or delete in feed.instruments or feed.subscriptions.
--   - streaming_app CANNOT create tables in feed or public.

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

-- Check 2: Explicitly assert denied public schema privileges (USAGE and CREATE)
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

-- Check 3: Assert startup query results rather than merely printing them
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

-- Print startup query output for terminal inspection
SELECT i.instrument_token, s.mode
FROM feed.subscriptions AS s
JOIN feed.instruments AS i ON i.id = s.instrument_id
WHERE s.enabled
ORDER BY i.instrument_token;

-- Check 4: Verify all write and DDL operations are denied
DO $$
DECLARE
    caught boolean;
BEGIN
    -- 4a: INSERT feed.instruments denied
    caught := false;
    BEGIN
        INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type)
        VALUES (8888888, 'DENY', 'DENY', 'DENY', 'EQ');
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: INSERT on feed.instruments was permitted'; END IF;

    -- 4b: UPDATE feed.instruments denied
    caught := false;
    BEGIN
        UPDATE feed.instruments SET trading_symbol = 'HACK' WHERE id = 1;
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: UPDATE on feed.instruments was permitted'; END IF;

    -- 4c: DELETE feed.instruments denied
    caught := false;
    BEGIN
        DELETE FROM feed.instruments WHERE id = 1;
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: DELETE on feed.instruments was permitted'; END IF;

    -- 4d: INSERT feed.subscriptions denied
    caught := false;
    BEGIN
        INSERT INTO feed.subscriptions (instrument_id, mode, enabled)
        VALUES (1, 'full', true);
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: INSERT on feed.subscriptions was permitted'; END IF;

    -- 4e: UPDATE feed.subscriptions denied
    caught := false;
    BEGIN
        UPDATE feed.subscriptions SET enabled = false WHERE instrument_id = 1;
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: UPDATE on feed.subscriptions was permitted'; END IF;

    -- 4f: DELETE feed.subscriptions denied
    caught := false;
    BEGIN
        DELETE FROM feed.subscriptions WHERE instrument_id = 1;
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: DELETE on feed.subscriptions was permitted'; END IF;

    -- 4g: CREATE TABLE in feed denied
    caught := false;
    BEGIN
        EXECUTE 'CREATE TABLE feed.forbidden (id int)';
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: CREATE TABLE in feed was permitted'; END IF;

    -- 4h: CREATE TABLE in public denied
    caught := false;
    BEGIN
        EXECUTE 'CREATE TABLE public.forbidden (id int)';
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'FAIL: CREATE TABLE in public was permitted'; END IF;

    RAISE NOTICE 'CHECK 4 PASS: All unauthorized mutation and DDL attempts correctly rejected for streaming_app';
END $$;

ROLLBACK;
