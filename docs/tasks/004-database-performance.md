# Task 004: Database performance baseline and evidence-driven tuning

Status: Ready for Antigravity investigation. Confirm Task 002 review fixes and validate the Task 003 dataset before measurements. Do not execute as part of Task 003.

## Objective

Measure tick/depth database reads and batched writes, identify bottlenecks, and evaluate targeted improvements while preserving schema constraints, complete snapshots, and runtime permissions.

Read `AGENTS.md`, `docs/local-database.md`, Task 002/003, their implementation reports, and `docs/verification/003-seed-io-review.md`. Treat unverified reported numbers as observations to reproduce, not established baselines. Apply the I/O batching and ownership skills when reviewing Go writes.

## Primary workload: mock replay

The agreed mock server reads one configured `stream_id` for one client, supports full-mode stock/futures packets, and never inserts data. Optimize its actual read contract:

- Filter by `stream_id`, a half-open receive-time range, and selected instrument IDs from client subscriptions.
- Page in deterministic `(received_at, id)` order using a keyset cursor, not OFFSET. Preserve tied timestamps across page boundaries.
- Return all full-mode scalar fields and provider token via catalogue join. Limit ticks before joining their depth; retrieve complete ten-level snapshots in one bounded query/page rather than a query per tick.
- Measure first/middle/late pages, all instruments and a narrow subscription subset, and page sizes 100 and 1,000. Use existing valid instrument IDs; do not assume ID 1 belongs to the recording.
- Existing `(received_at, id)` indexes support global replay but may scan unrelated recordings. Evaluate `(stream_id, received_at, id)` as a candidate, with measured storage/write costs. Compare single- and multi-stream datasets in isolated fixture identities. Do not add a redundant depth index when its primary key already serves tick lookups.

No index is mandatory merely because it is proposed here. Retain changes when evidence supports them. A useful performance baseline with no schema change is a valid outcome.

## Baseline

- Use Task 003's reproducible dataset and record its parameters, actual row counts, IDs, and time range. Start with 100,000 ticks and 1 million depth rows; enlarge only when baseline findings justify it.
- Record PostgreSQL version, hardware, relevant settings, indexes, table/index sizes, batch configuration, and cache conditions.
- Run ANALYZE and parameterized `EXPLAIN (ANALYZE, BUFFERS)` for latest tick, instrument history, keyset replay, depth retrieval, and replay with complete depth.
- Exercise selective and broader ranges. Record actual rows, planning/execution times, buffer hits/reads, scan types, sorts, and a small number of repeated runs. Do not equate planner cost units with elapsed time.
- Benchmark writes separately using isolated synthetic stream identities; measure committed ticks and depth rows, throughput, elapsed time, and batch size. Keep correctness checks active. Do not mix baseline datasets or delete existing recordings.

## Improvements

Use measured evidence to choose experiments, such as batch-size changes, insert/COPY strategies, or index changes. Compare one consequential variable at a time with the same workload and preserve reproducible before/after results.

An index adds storage and write cost; retain it for demonstrated query value. A sequential scan may be correct for broad ranges. Do not force scans to manufacture favorable evidence. Do not weaken constraints, durability, or snapshot atomicity for throughput.

Use isolated experiments for potentially disruptive changes. Persistent schema changes require versioned migrations and review; major changes such as hypertables, retention, or compression need an agreed design. Report recommendations as proposals until authorized.

## Deliverables

- Reproducible measurement commands/scripts and captured query plans.
- `docs/implementation/004-database-performance.md` with baseline, experiments, measured results, retained changes, and limitations. No invented service-level targets or end-to-end streaming claims.
- Supply the exact mock replay query, recommended page size, and relevant index rationale as the handoff to [Task 005](005-mock-websocket.md). Changes to query tooling and additive measured index migrations are in scope; changing the seed writer implementation is a separate proposal unless explicitly requested.
- Rerun relevant correctness/permission checks after retained changes; independent verification belongs in a separate review record.

No cloud provisioning, live market integration, WebSocket server, or commits/tags/pushes without a separate request.
