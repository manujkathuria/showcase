package db

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"

	"intraday-trading/internal/generator"
)

func getTestPool(t *testing.T) *Config {
	cfg := LoadConfigFromEnv()
	return &cfg
}

func TestEnsureSyntheticInstruments(t *testing.T) {
	ctx := context.Background()
	cfg := getTestPool(t)

	pool, err := Connect(ctx, *cfg)
	if err != nil {
		t.Skipf("skipping db integration test: database unavailable: %v", err)
	}
	defer pool.Close()

	cleanup := func() {
		tx, err := pool.Begin(ctx)
		if err == nil {
			_, _ = tx.Exec(ctx, "SET LOCAL ROLE streaming_owner;")
			_, _ = tx.Exec(ctx, "DELETE FROM feed.instruments WHERE instrument_token BETWEEN 9999001 AND 9999003")
			_ = tx.Commit(ctx)
		}
	}

	cleanup()
	defer cleanup()

	// 1. Initial insert of 3 instruments
	insts, err := EnsureSyntheticInstruments(ctx, pool, 3)
	if err != nil {
		t.Fatalf("EnsureSyntheticInstruments error: %v", err)
	}
	if len(insts) != 3 {
		t.Fatalf("expected 3 instruments, got %d", len(insts))
	}

	// 2. Rerun check (idempotent)
	insts2, err := EnsureSyntheticInstruments(ctx, pool, 3)
	if err != nil {
		t.Fatalf("EnsureSyntheticInstruments rerun error: %v", err)
	}
	for i := range insts {
		if insts[i].ID != insts2[i].ID || insts[i].Token != insts2[i].Token {
			t.Errorf("instrument mismatch on rerun: %+v vs %+v", insts[i], insts2[i])
		}
	}
}

func TestBatchInserterAndStreamStatus(t *testing.T) {
	ctx := context.Background()
	cfg := getTestPool(t)

	pool, err := Connect(ctx, *cfg)
	if err != nil {
		t.Skipf("skipping db integration test: database unavailable: %v", err)
	}
	defer pool.Close()

	testStreamID := uuid.MustParse("e0000000-0000-0000-0000-000000000099")

	cleanup := func() {
		tx, err := pool.Begin(ctx)
		if err == nil {
			_, _ = tx.Exec(ctx, "SET LOCAL ROLE streaming_owner;")
			_, _ = tx.Exec(ctx, "DELETE FROM market.order_depth WHERE tick_id IN (SELECT id FROM market.live_ticks WHERE stream_id = $1)", testStreamID)
			_, _ = tx.Exec(ctx, "DELETE FROM market.live_ticks WHERE stream_id = $1", testStreamID)
			_ = tx.Commit(ctx)
		}
	}

	cleanup()
	defer cleanup()

	// 1. Ensure 2 synthetic instruments
	insts, err := EnsureSyntheticInstruments(ctx, pool, 2)
	if err != nil {
		t.Fatalf("EnsureSyntheticInstruments error: %v", err)
	}

	genCfg := generator.Config{
		InstrumentCount:    2,
		TicksPerInstrument: 10,
		StartTime:          time.Date(2026, 10, 9, 9, 15, 0, 0, time.UTC),
		TickInterval:       100 * time.Millisecond,
		Seed:               42,
		StreamID:           testStreamID,
		BatchSize:          10,
	}

	totalExpectedTicks := genCfg.TotalTicks()

	// Initial status check: should be empty
	status, err := CheckStreamStatus(ctx, pool, testStreamID, totalExpectedTicks)
	if err != nil {
		t.Fatalf("CheckStreamStatus error: %v", err)
	}
	if status.IsComplete || status.TickCount != 0 || status.DepthCount != 0 {
		t.Fatalf("expected empty stream, got %+v", status)
	}

	gen, err := generator.NewMarketDataGenerator(genCfg, insts)
	if err != nil {
		t.Fatalf("NewMarketDataGenerator error: %v", err)
	}

	buf := generator.NewBatchBuffer(genCfg.BatchSize)
	inserter := NewBatchInserter(pool, genCfg.BatchSize)

	var committed int64
	for gen.NextBatch(buf) {
		if err := inserter.InsertBatch(ctx, buf); err != nil {
			t.Fatalf("InsertBatch error: %v", err)
		}
		committed += int64(buf.Len())
	}

	if committed != totalExpectedTicks {
		t.Fatalf("expected %d committed ticks, got %d", totalExpectedTicks, committed)
	}

	// Verify stream status after full load: should be complete
	status, err = CheckStreamStatus(ctx, pool, testStreamID, totalExpectedTicks)
	if err != nil {
		t.Fatalf("CheckStreamStatus post-load error: %v", err)
	}
	if !status.IsComplete || status.TickCount != totalExpectedTicks || status.DepthCount != totalExpectedTicks*10 {
		t.Fatalf("expected complete status (%d ticks, %d depth), got %+v",
			totalExpectedTicks, totalExpectedTicks*10, status)
	}

	// Verify depth integrity in database
	var depthPerTickCount int
	err = pool.QueryRow(ctx, `
		SELECT count(DISTINCT tick_id)
		FROM market.order_depth
		WHERE tick_id IN (SELECT id FROM market.live_ticks WHERE stream_id = $1)
	`, testStreamID).Scan(&depthPerTickCount)
	if err != nil {
		t.Fatalf("failed to query depth count: %v", err)
	}
	if int64(depthPerTickCount) != totalExpectedTicks {
		t.Fatalf("expected %d distinct ticks with depth, got %d", totalExpectedTicks, depthPerTickCount)
	}
}
