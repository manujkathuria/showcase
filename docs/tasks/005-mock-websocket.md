# Task 005: Zerodha-compatible database replay WebSocket server

Status: Planned; implement after Task 004 provides a verified replay query. This is the next functional slice, not part of database performance work.

## Objective and scope

Build a Go mock WebSocket server that reads one configured `stream_id` from local market tables and emits full-mode stock/futures packets for one connected client. It emulates the documented market-data subset of Kite, not the entire broker API.

Read `AGENTS.md`, relevant routed Go skills, local database docs, and Task 004's query handoff. Verify the protocol against [Kite's WebSocket specification](https://kite.trade/docs/connect/v3/websocket/) and the official Go client codec when the page leaves details ambiguous. Document any intentional mock deviations.

## Contract

- Local endpoint and read-only DB configuration are explicit. Use `streaming_app`; no inserts, migrations, ANALYZE, or updates from the server. Do not embed or require real Kite credentials. Bind locally by default.
- One configured recording, one concurrent client; reject a second connection explicitly. Each new accepted connection starts a fresh replay. No automatic loop at recording end in this slice.
- Accept JSON `subscribe`, `unsubscribe`, and `mode` commands using provider instrument tokens. Support `full` only; report unsupported modes clearly. Bound input, unique subscriptions, and output message size. Handle invalid commands without panics; distinguish successful command writes from provider acknowledgments, which the documented protocol does not promise.
- Map tokens to the recording's instruments. Do not modify database subscriptions when a client changes its subscriptions. Define unknown-token behavior explicitly.
- Begin playback once valid subscriptions and full-mode configuration exist. Replays use a monotonically advancing recording cursor; later subscription changes affect remaining ticks, not previously skipped events. An empty subscription set pauses playback; document command ordering and this local behavior.
- Use Task 004's bounded keyset read query. Reconstruct tick plus five bid/five ask levels and preserve receive-time/id order. Do not load the full recording into memory or query depth once per tick.
- Encode full 184-byte stock/futures packets and documented packet-count/length framing explicitly, with verified byte order, numeric ranges, and two padding bytes per depth level. Do not serialize Go struct memory. Five levels per side is a maximum populated depth: allow empty/zero slots and never require five nonempty bids or asks. Current storage preserves ten wire slots as rows, including empty slots; detect missing recorded slots under that contract and reject unrepresentable values visibly. Do not silently drop a tick with no joined depth rows.
- Binary market data is separate from text control/errors. Emit the documented one-byte application heartbeat when idle using a defined local interval; do not conflate it with WebSocket ping/pong. Empty depth levels are preserved.
- Configurable positive playback-speed factor; pace by recorded receive-time differences using a monotonic playback origin. Preserve source timestamps rather than replacing them with wall clock. Tied times preserve cursor order. Bound waits and react to cancellation.
- Define end-of-recording signaling, read/write deadlines, DB errors, and slow-client behavior. Keep one writer owner for frames/control messages, bounded queues, and coordinated reader/replay shutdown. Never silently drop snapshots to meet a speed target.

## Verification and deliverables

- Unit tests decode generated frames independently of the encoder and assert expected full-mode fields, depth order, lengths, and padding. Include malformed/out-of-range stored data.
- Local integration tests exercise actual WebSocket subscription/mode commands, subscribed-only output, unsubscribe, tied timestamps across pages, heartbeats, recording end, client disconnect, cancellation, and second-client rejection. Verify DB writes are unnecessary and denied.
- Use small isolated fixtures and deterministic test timing where practical. Run appropriate Go checks and race detection for exercised concurrency; benchmark encode/reuse allocations separately from networking when making allocation claims.
- Provide server command, repeatable local run instructions, and `docs/implementation/005-mock-websocket.md` with verified behavior and limitations. Dependencies must have an explained purpose; keep replay and codec logic separate from DB/network libraries.

## Outside scope

Live Zerodha ingestion, multiple recordings/clients, index packets, ltp/quote modes, broker order APIs, sink writes, seven-day retention, exactly-once network delivery, and cloud deployment. Do not commit, tag, or push without a separate request.
