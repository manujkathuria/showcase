# Verification 004: Database performance

Date: 2026-10-09

Status: Changes requested. Replay query/index are operational; benchmark and evidence issues remain.

Task: [004-database-performance](../tasks/004-database-performance.md)

Implementation: [004-database-performance](../implementation/004-database-performance.md)

## Independent checks

Verified `live_ticks_stream_replay_idx` exists on `(stream_id, received_at, id)`. Ran the updated rollback-only market correctness checks successfully against seeded data.

Ran all six queries in `006_replay_benchmarks.sql` with default planner settings. Captured [raw plans and dataset counts](artifacts/004-replay-plans.txt). Queries used the stream index and depth primary key. First 100-tick replay returned 1,000 depth rows in 1.455 ms; middle and late 1,000-tick pages returned 10,000 rows in 11.462 and 11.450 ms; narrow 100-tick replay took 1.361 ms. These are single local observations, not latency guarantees, cold-cache measurements, or client-end-to-end throughput.

No write benchmark, index removal, or schema mutation was performed in this review. Only existing read queries and rollback-only correctness tests were run.

## Findings for Antigravity

1. **Make replay experiments configurable.** The advertised `page_limit` override is unused: limits, instrument IDs, cursor IDs/times, and some range bounds remain hardcoded. Parameterize or derive them from the selected dataset. Capture first/middle/late pages at both 100 and 1,000 ticks with all/subset subscriptions and explicit raw plans. Safely quote timestamp/UUID literals rather than require callers to inject SQL quoting.
2. **Correct benchmark timing and cleanup.** `BenchmarkBatchedWrites` times generator construction, generation, setup, inserts, and cleanup under Go's benchmark clock. Custom throughput includes generation, excludes cleanup, and reports only the last iteration. Aggregate committed work over a defined elapsed interval; measure generation separately and label included phases. Cleanup uses two nontransactional DELETEs and ignores errors. Restrict cleanup to created benchmark identities, run it atomically, check errors, and arrange cleanup on failure. Add an explicit integration-benchmark opt-in so generic benchmark runs do not unexpectedly write to the configured DB. Assert complete snapshots before cleanup.
3. **Make performance claims supported and internally consistent.** The report's 10,000-tick elapsed times do not reconcile with listed tick rates (e.g. 1.80 s implies about 5,556 ticks/s, not 6,113). Preserve raw results and explain measurement intervals. Buffer reads do not prove cold cache; batch-size correlations do not establish WAL lock bottlenecks; buffer capacity is not measured process resident memory. Remove those unsupported claims, the universal constant-time claim, and unmeasured standalone-depth-index size estimate. Quantify candidate index write cost with comparable data, or label it unmeasured.
4. **Enforce index migration semantics.** Migration 003 uses `IF NOT EXISTS`, contrary to the agreed fail-on-rerun approach; it can silently accept an incompatible same-named index. Use explicit migration semantics or validate the existing definition and fail on conflict. Do not drop/recreate the applied index merely to change the script's rerun behavior.

## Mock handoff boundary

Five levels per side is the maximum populated market depth, not a minimum. Valid empty/zero levels must be replayed, not rejected. The documented stock/futures full packet nevertheless has ten fixed wire slots. The current storage contract preserves all ten slots, including empty slots, as rows; under that representation absent rows indicate missing recorded slot data, not simply limited market liquidity. The inner join can hide that storage defect or drop a tick with no stored depth rows. Preserve ticks during retrieval and validate against the agreed storage representation, never against a requirement for five nonempty levels. If storage later omits empty slots, explicitly define reconstruction and how absent depth is distinguished from a failed write before changing validation. Subscription changes must invalidate/filter prefetched rows before sending.

## Closure

Follow-up source review before commit: the index migration now fails on rerun, replay benchmark scripts expose more parameters, and write benchmarks require explicit opt-in and aggregate insertion metrics. These are improvements, but corrected experiments have not been independently rerun. The deferred failure cleanup still ignores errors and accumulates closures across iterations; snapshot integrity still relies on aggregate counts. Full performance acceptance is therefore pending, even though the implementation can be committed as a milestone.

Review corrections, rerun relevant correctness/permission checks, and record reproducible read/write evidence. Keep page size configurable; 1,000 is a candidate throughput-oriented setting, not an established optimum. Full Task 004 acceptance remains pending.
