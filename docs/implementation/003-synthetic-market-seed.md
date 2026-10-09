# Implementation 003: Go synthetic market-data seed generator

Task Reference: [docs/tasks/003-synthetic-market-seed.md](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/tasks/003-synthetic-market-seed.md)
Status: Implementation complete; pending independent review
Implemented: 2026-10-09

---

## 1. Overview

Built a high-performance Go command-line tool (`cmd/seed-generator`) that generates reproducible, protocol-representable stock and futures market data snapshots and loads them into `market.live_ticks` and `market.order_depth`.

Key characteristics:
- **Zero-allocation Generation Loop**: Designed strictly adhering to [go-data-ownership](file:///Users/manujkathuria/workspace/gidh/intraday-trading/.agents/skills/go-data-ownership/SKILL.md), utilizing concrete structs, fixed-capacity arrays for order depth levels (`[5]DepthLevel`), and a reusable `BatchBuffer` (yielding `0 B/op` and `0 allocs/op` in benchmarks).
- **High-Throughput Batched Writes**: Leverages `pgx/v5` with multi-row batching for ticks and native binary streaming `CopyFrom` (`DepthCopySource`) for order depth within atomic per-batch transactions.
- **Catalogue & Stream Safety**: Creates synthetic instruments in `feed.instruments` without touching `feed.subscriptions`. Enforces pre-flight database name validation (`intraday_streaming`) and idempotent rerun safety.

---

## 2. Artifacts Produced

| Type | Path | Purpose |
| --- | --- | --- |
| **CLI Entrypoint** | [`cmd/seed-generator/main.go`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/cmd/seed-generator/main.go) | CLI application with flag parsing, connection setup, progress reporting, and statistics. |
| **Domain Models & Generator** | [`internal/generator/model.go`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/internal/generator/model.go), [`internal/generator/generator.go`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/internal/generator/generator.go) | Concrete domain structs, fixed depth arrays, reusable `BatchBuffer`, and deterministic generation loop. |
| **Unit Tests & Benchmarks** | [`internal/generator/generator_test.go`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/internal/generator/generator_test.go) | Validates determinism, OHLC bounds, depth price ladder ordering, buffer reuse, and allocation-free loop. |
| **Database Client & Inserter** | [`internal/db/client.go`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/internal/db/client.go), [`internal/db/inserter.go`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/internal/db/inserter.go) | Connection pool with DB guard, synthetic catalogue manager, `DepthCopySource` (`pgx.CopyFromSource`), and transactional batch inserter. |
| **DB Integration Tests** | [`internal/db/db_test.go`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/internal/db/db_test.go) | Integration tests for instrument catalogue creation, stream idempotency, and atomic depth insertion. |
| **Documentation** | [`docs/local-database.md`](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/local-database.md) | Updated with CLI usage, smoke presets, and dataset reproduction instructions. |

---

## 3. Engineering Decisions & Data Ownership

### Representation and Memory Model
- **Fixed-Size Depth Arrays**: Each tick represents its snapshot order depth as `DepthSnapshot` with `Bids [5]DepthLevel` and `Asks [5]DepthLevel`. No slice pointers or separate heap allocations are created per depth row.
- **Value-Based Timestamps**: `ReceivedAt`, `ExchangeAt`, and `LastTradeAt` are passed and stored by value (`time.Time`), preventing pointer escapes to the heap during iteration.
- **Reusable `BatchBuffer`**: A single preallocated slice `[]TickRecord` with capacity equal to `batchSize` is allocated at startup and reused across batches via `buf.Reset()`.
- **Zero-Allocation Generation Benchmark**:
  ```text
  BenchmarkGenerateBatch-8   18   67470817 ns/op   0 B/op   0 allocs/op
  ```

### Database Ingestion & Transactional Integrity
- **Batch Pipeline**:
  1. Inserts `N` ticks into `market.live_ticks` using `pgx.Batch` with `RETURNING id`.
  2. Maps returned IDs to each record's depth snapshot.
  3. Streams `N * 10` depth rows via `tx.CopyFrom` implementing `pgx.CopyFromSource` with an internal reusable values slice.
  4. Commits atomically per batch.
- **Partial Failure & Cancellation**: Interrupted runs (SIGINT/SIGTERM) roll back the in-flight batch, ensuring the database contains only complete tick and depth snapshots.

---

## 4. Retained Dataset Metadata & Handoff to Task 004

The generator populated the baseline dataset for subsequent database profiling and query optimization (Task 004):

| Parameter | Configured Value |
| --- | --- |
| **Stream UUID** | `c0000000-0000-0000-0000-000000000003` |
| **Instrument Count** | 10 (`SIM_SYNTH_01` to `SIM_SYNTH_10`) |
| **Instrument Tokens** | `9910001` through `9910010` |
| **Database Instrument IDs** | `83` through `92` |
| **Ticks per Instrument** | 10,000 |
| **Total Committed Ticks** | 100,000 |
| **Total Committed Depth** | 1,000,000 (exactly 10 levels per tick) |
| **Time Span** | `2026-10-09T09:15:00+05:30` to `2026-10-09T09:31:40+05:30` (100ms interval) |
| **Random Seed** | `42` |
| **Batch Size** | 1,000 ticks (10,000 depth rows per transaction) |

### Load Performance Record
- **Elapsed Load Time**: `9.873s`
- **Tick Ingestion Rate**: `10,128.6 ticks/sec`
- **Depth Ingestion Rate**: `101,285.8 depth_rows/sec`
- **Peak Process Heap Allocation**: `1.78 MB`

---

## 5. Verification Commands & Test Evidence

### 1. Unit Tests and Benchmarks
```bash
go test -v -bench=. -benchmem ./...
```
Output:
```text
=== RUN   TestEnsureSyntheticInstruments
--- PASS: TestEnsureSyntheticInstruments (0.05s)
=== RUN   TestBatchInserterAndStreamStatus
--- PASS: TestBatchInserterAndStreamStatus (0.04s)
=== RUN   TestDeterministicGeneration
--- PASS: TestDeterministicGeneration (0.00s)
=== RUN   TestBoundsAndCoherence
--- PASS: TestBoundsAndCoherence (0.00s)
=== RUN   TestBufferReuse
--- PASS: TestBufferReuse (0.00s)
BenchmarkGenerateBatch-8   18   67470817 ns/op   0 B/op   0 allocs/op
PASS
```

### 2. Smoke Run (Small Dataset Verification)
```bash
go run ./cmd/seed-generator -smoke
```
Generates 2 instruments × 50 ticks = 100 ticks, 1,000 depth rows in `22ms`.

### 3. Full Production-Scale Load
```bash
go run ./cmd/seed-generator \
  -instruments=10 \
  -ticks-per-instrument=10000 \
  -batch-size=1000 \
  -stream-id="c0000000-0000-0000-0000-000000000003"
```

### 4. Rerun Idempotency Test
```bash
go run ./cmd/seed-generator \
  -instruments=10 \
  -ticks-per-instrument=10000 \
  -stream-id="c0000000-0000-0000-0000-000000000003"
```
Output:
```text
[INFO] Stream c0000000-0000-0000-0000-000000000003 already exists with 100000 ticks and 1000000 depth rows. Idempotent skip.
```

---

## 6. Next Steps

- Handoff dataset metadata and query shapes to [Task 004: Database performance profiling](file:///Users/manujkathuria/workspace/gidh/intraday-trading/docs/tasks/004-database-performance.md).
- Independent review and verification are to be recorded by the delivery lead in `docs/verification/003-synthetic-market-seed.md`.
