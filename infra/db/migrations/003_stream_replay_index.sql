-- Migration 003: Stream-scoped keyset replay index
--
-- Creates composite B-tree index `market.live_ticks_stream_replay_idx` on `(stream_id, received_at, id)`
-- to eliminate multi-stream scan degradation during mock streaming replay.
--
-- Execution instructions:
--   psql -v ON_ERROR_STOP=1 -d intraday_streaming -f infra/db/migrations/003_stream_replay_index.sql
--
-- Rerun behavior:
--   This migration intentionally avoids IF NOT EXISTS. Rerunning against an existing
--   database will fail visibly on index creation, preventing silent schema drift.

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

CREATE INDEX live_ticks_stream_replay_idx
    ON market.live_ticks (stream_id, received_at, id);

COMMIT;
