package db

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"

	"intraday-trading/internal/generator"
)

// BenchmarkBatchedWrites benchmarks transactional batch write throughput across various batch sizes.
// Requires explicit opt-in via RUN_DB_BENCHMARKS=1 to prevent unexpected database writes during routine test runs.
func BenchmarkBatchedWrites(b *testing.B) {
	if os.Getenv("RUN_DB_BENCHMARKS") != "1" {
		b.Skip("skipping database write benchmark; set RUN_DB_BENCHMARKS=1 to enable")
	}

	ctx := context.Background()
	pool, err := Connect(ctx, LoadConfigFromEnv())
	if err != nil {
		b.Fatalf("failed to connect: %v", err)
	}
	defer pool.Close()

	instruments, err := EnsureSyntheticInstruments(ctx, pool, 10)
	if err != nil {
		b.Fatalf("failed to ensure instruments: %v", err)
	}

	batchSizes := []int{250, 500, 1000, 2500, 5000}
	totalTicksPerRun := 10000 // 10,000 ticks = 100,000 depth rows per test run

	for _, bs := range batchSizes {
		b.Run(fmt.Sprintf("BatchSize_%d", bs), func(b *testing.B) {
			var (
				totalCommittedTicks int64
				totalInsertDuration time.Duration
				totalGenDuration    time.Duration
			)

			for n := 0; n < b.N; n++ {
				streamID := uuid.New() // isolated stream ID per iteration

				// Ensure cleanup executes even if the benchmark iteration encounters an error
				defer func(sid uuid.UUID) {
					cleanCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
					defer cancel()
					tx, err := pool.Begin(cleanCtx)
					if err == nil {
						_, _ = tx.Exec(cleanCtx, "SET LOCAL ROLE streaming_owner;")
						_, _ = tx.Exec(cleanCtx, "DELETE FROM market.order_depth WHERE tick_id IN (SELECT id FROM market.live_ticks WHERE stream_id = $1)", sid)
						_, _ = tx.Exec(cleanCtx, "DELETE FROM market.live_ticks WHERE stream_id = $1", sid)
						_ = tx.Commit(cleanCtx)
					}
				}(streamID)

				cfg := generator.Config{
					StreamID:           streamID,
					InstrumentCount:    len(instruments),
					TicksPerInstrument: totalTicksPerRun / len(instruments),
					StartTime:          time.Date(2026, 10, 9, 9, 15, 0, 0, time.FixedZone("IST", 5*3600+1800)),
					TickInterval:       100 * time.Millisecond,
					BatchSize:          bs,
					Seed:               int64(n + 1000),
				}

				gen, err := generator.NewMarketDataGenerator(cfg, instruments)
				if err != nil {
					b.Fatalf("failed to create generator: %v", err)
				}

				// Pre-allocate batch buffers to measure pure DB insertion separately from generator memory setup
				var batches []*generator.BatchBuffer
				genStart := time.Now()
				for {
					buf := generator.NewBatchBuffer(bs)
					if !gen.NextBatch(buf) {
						break
					}
					batches = append(batches, buf)
				}
				totalGenDuration += time.Since(genStart)

				inserter := NewBatchInserter(pool, bs)

				// Timed DB insertion section
				insertStart := time.Now()
				committedThisRun := 0
				for _, buf := range batches {
					if err := inserter.InsertBatch(ctx, buf); err != nil {
						b.Fatalf("failed insert batch: %v", err)
					}
					committedThisRun += buf.Len()
				}
				iterInsertDuration := time.Since(insertStart)

				totalInsertDuration += iterInsertDuration
				totalCommittedTicks += int64(committedThisRun)

				// Assert complete snapshots before cleanup
				status, err := CheckStreamStatus(ctx, pool, streamID, int64(totalTicksPerRun))
				if err != nil {
					b.Fatalf("stream integrity check failed: %v", err)
				}
				if !status.IsComplete {
					b.Fatalf("incomplete stream detected: got %d ticks and %d depth rows", status.TickCount, status.DepthCount)
				}

				// Atomic cleanup of benchmark data
				cleanTx, err := pool.Begin(ctx)
				if err != nil {
					b.Fatalf("failed to begin cleanup tx: %v", err)
				}
				if _, err := cleanTx.Exec(ctx, "SET LOCAL ROLE streaming_owner;"); err != nil {
					_ = cleanTx.Rollback(ctx)
					b.Fatalf("failed to set role for cleanup: %v", err)
				}
				if _, err := cleanTx.Exec(ctx, "DELETE FROM market.order_depth WHERE tick_id IN (SELECT id FROM market.live_ticks WHERE stream_id = $1)", streamID); err != nil {
					_ = cleanTx.Rollback(ctx)
					b.Fatalf("failed to delete depth rows: %v", err)
				}
				if _, err := cleanTx.Exec(ctx, "DELETE FROM market.live_ticks WHERE stream_id = $1", streamID); err != nil {
					_ = cleanTx.Rollback(ctx)
					b.Fatalf("failed to delete live ticks: %v", err)
				}
				if err := cleanTx.Commit(ctx); err != nil {
					b.Fatalf("failed to commit cleanup: %v", err)
				}
			}

			if totalInsertDuration > 0 {
				insertTicksPerSec := float64(totalCommittedTicks) / totalInsertDuration.Seconds()
				insertDepthPerSec := float64(totalCommittedTicks*10) / totalInsertDuration.Seconds()
				b.ReportMetric(insertTicksPerSec, "db_ticks/sec")
				b.ReportMetric(insertDepthPerSec, "db_depth/sec")
			}
			if totalGenDuration > 0 {
				genTicksPerSec := float64(totalCommittedTicks) / totalGenDuration.Seconds()
				b.ReportMetric(genTicksPerSec, "gen_ticks/sec")
			}
		})
	}
}
