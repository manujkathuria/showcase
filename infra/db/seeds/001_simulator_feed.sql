-- Seed 001: Local simulator feed fixtures
--
-- ============================================================================
-- WARNING: THESE FIXTURES ARE FOR LOCAL SIMULATION TESTING ONLY.
-- DO NOT USE THESE SYNTHETIC TOKENS OR SYMBOLS FOR LIVE KITE SUBSCRIPTIONS.
-- ============================================================================
--
-- Provides two enabled full-mode subscriptions and one disabled subscription
-- with synthetic instrument metadata.
--
-- Execution instructions:
--   Run as an authorized administrator connection:
--     psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/seeds/001_simulator_feed.sql
--
-- Repeatability:
--   - Safe to rerun: does not duplicate rows or overwrite existing catalogue data.
--   - Fails visibly on conflicts if an existing instrument or subscription
--     has conflicting attributes for the same token or symbol.

\set ON_ERROR_STOP on

BEGIN;

-- Guard: Ensure execution only against the intended database
DO $$
BEGIN
    IF current_database() <> 'intraday_streaming' THEN
        RAISE EXCEPTION 'Refusing seed: expected database "intraday_streaming", connected to "%"', current_database();
    END IF;
END $$;

SET LOCAL ROLE streaming_owner;

CREATE TEMPORARY TABLE _fixture_catalog (
    instrument_token bigint,
    exchange         text,
    trading_symbol   text,
    segment          text,
    instrument_type  text,
    expiry           date,
    sub_mode         text,
    sub_enabled      boolean
) ON COMMIT DROP;

INSERT INTO _fixture_catalog (
    instrument_token, exchange, trading_symbol, segment, instrument_type, expiry, sub_mode, sub_enabled
) VALUES
    (9900001, 'SIM', 'SIM_INFY',      'SIM_EQ',  'EQ',  NULL,         'full', true),
    (9900002, 'SIM', 'SIM_NIFTY_FUT', 'SIM_FUT', 'FUT', '2026-12-31', 'full', true),
    (9900003, 'SIM', 'SIM_RELIANCE',  'SIM_EQ',  'EQ',  NULL,         'full', false);

-- Validate against conflicting existing catalogue entries (fail visibly without overwriting)
DO $$
DECLARE
    conflict RECORD;
BEGIN
    FOR conflict IN
        SELECT
            f.instrument_token AS fix_token,
            f.trading_symbol   AS fix_symbol,
            i.instrument_token AS exist_token,
            i.exchange         AS exist_exchange,
            i.trading_symbol   AS exist_symbol,
            i.segment          AS exist_segment,
            i.instrument_type  AS exist_type,
            i.expiry           AS exist_expiry
        FROM _fixture_catalog f
        JOIN feed.instruments i
          ON i.instrument_token = f.instrument_token
          OR (i.exchange = f.exchange AND i.trading_symbol = f.trading_symbol)
        WHERE i.instrument_token <> f.instrument_token
           OR i.exchange <> f.exchange
           OR i.trading_symbol <> f.trading_symbol
           OR i.segment <> f.segment
           OR i.instrument_type <> f.instrument_type
           OR i.expiry IS DISTINCT FROM f.expiry
    LOOP
        RAISE EXCEPTION 'Incompatible instrument catalogue data detected: fixture (token=%, symbol=%) conflicts with existing instrument (token=%, exchange=%, symbol=%, segment=%, type=%, expiry=%)',
            conflict.fix_token, conflict.fix_symbol,
            conflict.exist_token, conflict.exist_exchange, conflict.exist_symbol,
            conflict.exist_segment, conflict.exist_type, conflict.exist_expiry;
    END LOOP;
END $$;

-- Validate against conflicting existing subscription entries
DO $$
DECLARE
    sub_conflict RECORD;
BEGIN
    FOR sub_conflict IN
        SELECT
            f.instrument_token,
            s.mode    AS exist_mode,
            s.enabled AS exist_enabled,
            f.sub_mode    AS fix_mode,
            f.sub_enabled AS fix_enabled
        FROM _fixture_catalog f
        JOIN feed.instruments i ON i.instrument_token = f.instrument_token
        JOIN feed.subscriptions s ON s.instrument_id = i.id
        WHERE s.mode <> f.sub_mode OR s.enabled <> f.sub_enabled
    LOOP
        RAISE EXCEPTION 'Incompatible subscription data detected for token %: existing subscription (mode=%, enabled=%) differs from fixture (mode=%, enabled=%)',
            sub_conflict.instrument_token, sub_conflict.exist_mode, sub_conflict.exist_enabled,
            sub_conflict.fix_mode, sub_conflict.fix_enabled;
    END LOOP;
END $$;

-- Insert instruments if they do not already exist
INSERT INTO feed.instruments (
    instrument_token, exchange, trading_symbol, segment, instrument_type, expiry
)
SELECT f.instrument_token, f.exchange, f.trading_symbol, f.segment, f.instrument_type, f.expiry
FROM _fixture_catalog f
WHERE NOT EXISTS (
    SELECT 1 FROM feed.instruments i WHERE i.instrument_token = f.instrument_token
);

-- Insert subscriptions if they do not already exist
INSERT INTO feed.subscriptions (
    instrument_id, mode, enabled
)
SELECT i.id, f.sub_mode, f.sub_enabled
FROM _fixture_catalog f
JOIN feed.instruments i ON i.instrument_token = f.instrument_token
WHERE NOT EXISTS (
    SELECT 1 FROM feed.subscriptions s WHERE s.instrument_id = i.id
);

COMMIT;
