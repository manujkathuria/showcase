# Seed generator: I/O batching review

Date: 2026-10-09

Scope: Code review of I/O batching opportunities. This is not full Task 003 acceptance or a database-performance comparison. No application code or retained dataset was changed.

## Current behavior

Ran `go test ./internal/generator -bench=. -benchmem -count=1` on Darwin/arm64, Apple M1. Tests passed; `BenchmarkGenerateBatch` reported `29,535,486 ns/op`, `0 B/op`, and `0 allocs/op`. This measures generation only. Database-write benchmarks and syscall tracing were not run.

`internal/db/inserter.go` uses one transaction per batch, pipelines individual tick INSERTs through `pgx.Batch`, reads their returned IDs, COPYs linked depth rows, and commits. These are useful existing batching mechanisms; the writer does not perform a synchronous database round trip for every tick.

The tick batch still executes one INSERT and returns one ID per tick. The implementation report calls this multi-row batching; it should distinguish pipelined statements from a multi-row INSERT. Actual syscall counts and kernel overhead have not been measured.

## Candidates for Task 004

1. Compare the existing pipeline with a bounded multi-row tick INSERT. Return `id, stream_id, sequence` and map IDs explicitly; never rely on RETURNING row order. Bound parameters/bytes and preserve transactional depth writes.
2. For larger loads, consider COPY into transaction-local staging followed by a set-based INSERT/RETURNING and linked depth loading. Extra staging and mapping cost may outweigh benefits; benchmark before adoption.
3. `DepthCopySource.Values` copies an entire TickRecord for each depth row. A pointer to the current record avoids expressing that large copy, but verify compiler behavior and benchmark before claiming a speedup. Reusing `[]any` alone does not establish zero allocations: interface assignments may allocate.
4. Each batch issues `SET LOCAL ROLE` separately. Consider connection setup or another justified approach only if role isolation remains correct for pooled connections and the cost is significant. Do not remove the role boundary for speed.
5. The sequential CLI configures a pool of ten connections with two minimum connections. Start from actual concurrency requirements; compare a single writer connection/smaller pool rather than assume more connections improve throughput.

## Correctness prerequisite

`CheckStreamStatus` treats matching aggregate tick/depth counts as proof of a matching complete dataset. A different random seed, time interval, or instrument distribution with the same total count is silently skipped. Counts also cannot prove ten depth levels for each tick. Resolve dataset parameter/content validation before optimizing rerun behavior; no performance change should preserve this incorrect success claim.

The CLI's final heap sample is not a peak-memory measurement. Correct the implementation report's peak claim or collect an actual peak observation. Generation-only zero allocations do not establish zero allocations in the database writer.

## Recommendation

Keep the existing batched writer as the baseline. First close generator correctness findings, then compare bounded strategies in Task 004 using fresh isolated stream identities, complete-snapshot checks, and recorded batch sizes. Do not attribute improvement to fewer kernel transitions without tracing evidence.
