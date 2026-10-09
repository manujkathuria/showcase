-- Migration 001: Feed configuration tables (instruments and subscriptions)
--
-- Creates the instrument catalogue and desired subscription configuration tables
-- in the feed schema. Both tables are owned by streaming_owner.
--
-- Execution instructions:
--   Run as an authorized administrator connection (e.g. database superuser or admin):
--     psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/migrations/001_feed_configuration.sql
--
-- Rerun behavior:
--   This migration intentionally avoids IF NOT EXISTS. Rerunning against an existing database
--   will fail visibly on table creation, preventing silent schema drift.

\set ON_ERROR_STOP on

BEGIN;

-- Guard: Ensure execution only against the intended database
DO $$
BEGIN
    IF current_database() <> 'intraday_streaming' THEN
        RAISE EXCEPTION 'Refusing migration: expected database "intraday_streaming", connected to "%"', current_database();
    END IF;
END $$;

SET LOCAL ROLE streaming_owner;

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

COMMIT;
