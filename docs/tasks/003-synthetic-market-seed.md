# Task 003: Go synthetic market-data seed generator

Status: Defined; blocked on Task 002 schema completion and review. Do not implement concurrently against an unsettled schema.

## Objective

Build a Go command-line seed generator that loads reproducible stock/futures full-mode tick and depth snapshots into `market.live_ticks` and `market.order_depth`. This is retained local simulation data, not a live source or WebSocket server. Database profiling and tuning belong to [Task 004](004-database-performance.md).

Read `AGENTS.md`, [Task 002](002-market-tick-storage.md), `docs/local-database.md`, and `.agents/skills/go-data-ownership/SKILL.md` before designing representations and batches.

## Generator contract

- Expose instrument count, ticks per instrument, start time, tick interval, random seed, stream UUID, and batch size. Validate ranges and total row counts before writes. Default to 10 instruments × 10,000 ticks and ten depth levels per tick; support much smaller smoke runs.
- Use clearly synthetic instruments separate from Task 001 fixtures, without creating or changing subscriptions. Never overwrite real catalogue data on conflicts.
- Generate deterministic semantic values and timestamps for identical parameters. Database-generated IDs need not be identical. Include tied timestamps and repeated prices; neither determines identity.
- Use scaled integer prices, coherent OHLC/depth values, cumulative volume, and explicit units. Keep source values within the intended Kite wire ranges so future encoding is possible. Describe this as protocol-representable synthetic data, not realistic market microstructure.
- Store five bids and five asks for each tick, including valid empty levels where a scenario requires them. Link through the inserted tick ID; never assume identity sequences are contiguous or infer IDs by arithmetic.
- Preallocate bounded batches with concrete structs and fixed depth arrays. Reuse buffers only when the database driver has finished consuming them. Do not build the whole dataset in memory.
- Use transactional batched writes, not one transaction/network round trip per tick. Choose a database driver and insert strategy with an explained benefit; setup-only allocation and necessary driver allocations are permitted and measured separately.
- Define cancellation and retry behavior. Each committed batch contains complete tick/depth snapshots; interrupted runs leave no partial snapshots.
- Rerunning the same dataset must not duplicate rows or silently accept conflicting content. Validate parameters/content identity and either resume a matching run or fail clearly. No truncate/delete/reset behavior in the default command.
- Require an explicit authorized seed connection; keep `streaming_app` read-only. Verify database name before mutation, do not log credentials, and never embed them in source code.

## Verification

- Unit-test deterministic generation, bounds, price/depth relationships, and buffer reuse. Benchmark generation after setup with allocation reporting; identify the exact measured operation.
- Integration-test a small load, matching rerun behavior, conflict rejection, cancellation, and atomic tick/depth writes. Verify expected counts and ten linked levels per committed tick.
- Report generated versus committed counts, elapsed time, write throughput, batch parameters, and peak memory observation. Keep generation-only and database-write performance separate.

## Handoff to database performance work

Record dataset identity, generator parameters, time range, actual instrument IDs, and committed tick/depth counts so Task 004 can reproduce queries against the correct data. No EXPLAIN experiments, index changes, server tuning, or comparative database optimization in this task. Basic load counters and generator allocation checks remain required to verify this implementation.

## Deliverables

- Go CLI and appropriate module/dependency setup, generator tests and benchmarks, and a documented small-run command.
- Updated local database instructions and `docs/implementation/003-synthetic-market-seed.md` with actual counts, generator allocation results, basic load statistics, dataset metadata, and commands run.
- Report unapplied/unrun steps honestly. Independent verification is recorded by the delivery lead. No commits, tags, pushes, WebSocket implementation, retention policy, or live trading in this task.
