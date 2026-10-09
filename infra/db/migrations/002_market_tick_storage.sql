-- Migration 002: Market tick and order depth storage
--
-- Creates schema `market` and tables `market.live_ticks` and `market.order_depth`
-- with required constraints, B-tree indexes, and read-only grants for `streaming_app`.
--
-- Execution instructions:
--   Run as an authorized administrator connection:
--     psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/migrations/002_market_tick_storage.sql
--
-- Rerun behavior:
--   This migration intentionally avoids IF NOT EXISTS. Rerunning against an existing
--   database will fail visibly on schema or table creation, preventing silent schema drift.

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

CREATE SCHEMA market;

CREATE TABLE market.live_ticks (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instrument_id       bigint NOT NULL REFERENCES feed.instruments (id),
    stream_id           uuid NOT NULL,
    sequence            bigint NOT NULL,
    received_at         timestamptz NOT NULL,
    exchange_at         timestamptz,
    last_trade_at       timestamptz,
    last_price          bigint NOT NULL,
    average_price       bigint NOT NULL,
    open_price          bigint NOT NULL,
    high_price          bigint NOT NULL,
    low_price           bigint NOT NULL,
    close_price         bigint NOT NULL,
    last_quantity       bigint NOT NULL,
    volume              bigint NOT NULL,
    total_buy_quantity  bigint NOT NULL,
    total_sell_quantity bigint NOT NULL,
    open_interest       bigint NOT NULL,
    open_interest_high  bigint NOT NULL,
    open_interest_low   bigint NOT NULL,

    CONSTRAINT live_ticks_stream_sequence_unique
        UNIQUE (stream_id, sequence),
    CONSTRAINT live_ticks_sequence_positive
        CHECK (sequence > 0),
    CONSTRAINT live_ticks_prices_nonnegative
        CHECK (
            last_price >= 0 AND average_price >= 0 AND open_price >= 0
            AND high_price >= 0 AND low_price >= 0 AND close_price >= 0
        ),
    CONSTRAINT live_ticks_quantities_nonnegative
        CHECK (
            last_quantity >= 0 AND volume >= 0
            AND total_buy_quantity >= 0 AND total_sell_quantity >= 0
        ),
    CONSTRAINT live_ticks_oi_nonnegative
        CHECK (
            open_interest >= 0 AND open_interest_high >= 0 AND open_interest_low >= 0
        )
);

CREATE TABLE market.order_depth (
    tick_id     bigint NOT NULL REFERENCES market.live_ticks (id),
    side        text NOT NULL,
    level       smallint NOT NULL,
    price       bigint NOT NULL,
    quantity    bigint NOT NULL,
    order_count bigint NOT NULL,

    CONSTRAINT order_depth_pk
        PRIMARY KEY (tick_id, side, level),
    CONSTRAINT order_depth_side_valid
        CHECK (side IN ('bid', 'ask')),
    CONSTRAINT order_depth_level_valid
        CHECK (level BETWEEN 1 AND 5),
    CONSTRAINT order_depth_values_nonnegative
        CHECK (price >= 0 AND quantity >= 0 AND order_count >= 0)
);

-- B-tree index for instrument-local latest and bounded-history queries
CREATE INDEX live_ticks_instrument_received_idx
    ON market.live_ticks (instrument_id, received_at DESC, id DESC);

-- B-tree index for deterministic replay across instruments
CREATE INDEX live_ticks_replay_idx
    ON market.live_ticks (received_at, id);

-- Grant privileges for runtime read role
ALTER DEFAULT PRIVILEGES FOR ROLE streaming_owner IN SCHEMA market
    GRANT SELECT ON TABLES TO streaming_app;

GRANT USAGE ON SCHEMA market TO streaming_app;
GRANT SELECT ON market.live_ticks, market.order_depth TO streaming_app;

COMMIT;
