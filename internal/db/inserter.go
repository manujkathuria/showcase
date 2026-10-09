package db

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"intraday-trading/internal/generator"
)

// StreamStatus indicates whether the dataset stream is already present, empty, or inconsistent.
type StreamStatus struct {
	IsComplete bool
	TickCount  int64
	DepthCount int64
}

// CheckStreamStatus inspects market tables for existing data under the target stream UUID.
func CheckStreamStatus(ctx context.Context, pool *pgxpool.Pool, streamID uuid.UUID, expectedTicks int64) (StreamStatus, error) {
	var status StreamStatus

	err := pool.QueryRow(ctx, `
		SELECT count(*)
		FROM market.live_ticks
		WHERE stream_id = $1
	`, streamID).Scan(&status.TickCount)
	if err != nil {
		return status, fmt.Errorf("failed to check existing tick count for stream %s: %w", streamID, err)
	}

	err = pool.QueryRow(ctx, `
		SELECT count(*)
		FROM market.order_depth d
		JOIN market.live_ticks t ON t.id = d.tick_id
		WHERE t.stream_id = $1
	`, streamID).Scan(&status.DepthCount)
	if err != nil {
		return status, fmt.Errorf("failed to check existing depth count for stream %s: %w", streamID, err)
	}

	expectedDepth := expectedTicks * 10

	if status.TickCount == expectedTicks && status.DepthCount == expectedDepth {
		status.IsComplete = true
		return status, nil
	}

	if status.TickCount > 0 || status.DepthCount > 0 {
		return status, fmt.Errorf("inconsistent partial dataset detected for stream %s: found %d ticks (expected %d) and %d depth rows (expected %d)",
			streamID, status.TickCount, expectedTicks, status.DepthCount, expectedDepth)
	}

	status.IsComplete = false
	return status, nil
}

// DepthCopySource streams order depth snapshots directly using pgx.CopyFromSource.
// Reuses a single slice of any to avoid per-row allocations.
type DepthCopySource struct {
	records []generator.TickRecord
	tickIDs []int64
	recIdx  int
	sideIdx int // 0 for bid, 1 for ask
	lvlIdx  int // 0 to 4
	values  []any
	err     error
}

// NewDepthCopySource initializes a reusable copy source for the given records and generated tick IDs.
func NewDepthCopySource(records []generator.TickRecord, tickIDs []int64) *DepthCopySource {
	return &DepthCopySource{
		records: records,
		tickIDs: tickIDs,
		recIdx:  0,
		sideIdx: 0,
		lvlIdx:  0,
		values:  make([]any, 6),
	}
}

// Next advances the iterator to the next depth row across all ticks in the batch.
func (s *DepthCopySource) Next() bool {
	if s.recIdx >= len(s.records) {
		return false
	}
	return true
}

// Values returns the current depth row values and advances internal counters.
func (s *DepthCopySource) Values() ([]any, error) {
	record := s.records[s.recIdx]
	tickID := s.tickIDs[s.recIdx]

	var lvl generator.DepthLevel
	if s.sideIdx == 0 {
		lvl = record.Depth.Bids[s.lvlIdx]
	} else {
		lvl = record.Depth.Asks[s.lvlIdx]
	}

	s.values[0] = tickID
	s.values[1] = lvl.Side
	s.values[2] = lvl.Level
	s.values[3] = lvl.Price
	s.values[4] = lvl.Quantity
	s.values[5] = lvl.OrderCount

	// Advance counter: 5 bids then 5 asks per tick
	s.lvlIdx++
	if s.lvlIdx >= 5 {
		s.lvlIdx = 0
		s.sideIdx++
		if s.sideIdx >= 2 {
			s.sideIdx = 0
			s.recIdx++
		}
	}

	return s.values, nil
}

// Err returns any error encountered during iteration.
func (s *DepthCopySource) Err() error {
	return s.err
}

// BatchInserter handles transactional batch writes of live ticks and linked order depth.
type BatchInserter struct {
	pool    *pgxpool.Pool
	tickIDs []int64
}

// NewBatchInserter creates an inserter with preallocated ID buffers.
func NewBatchInserter(pool *pgxpool.Pool, maxBatchSize int) *BatchInserter {
	return &BatchInserter{
		pool:    pool,
		tickIDs: make([]int64, maxBatchSize),
	}
}

// InsertBatch writes a batch of ticks and their 10 depth levels in a single atomic transaction.
func (bi *BatchInserter) InsertBatch(ctx context.Context, buf *generator.BatchBuffer) error {
	if buf.Len() == 0 {
		return nil
	}

	records := buf.Records
	batchSize := len(records)

	if len(bi.tickIDs) < batchSize {
		bi.tickIDs = make([]int64, batchSize)
	}
	tickIDs := bi.tickIDs[:batchSize]

	tx, err := bi.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("failed to begin batch transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, "SET LOCAL ROLE streaming_owner;"); err != nil {
		return fmt.Errorf("failed to set role streaming_owner: %w", err)
	}

	// 1. Batch insert ticks and collect generated IDs
	batch := &pgx.Batch{}
	insertTickSQL := `
		INSERT INTO market.live_ticks (
			instrument_id, stream_id, sequence, received_at, exchange_at, last_trade_at,
			last_price, average_price, open_price, high_price, low_price, close_price,
			last_quantity, volume, total_buy_quantity, total_sell_quantity,
			open_interest, open_interest_high, open_interest_low
		) VALUES (
			$1, $2, $3, $4, $5, $6,
			$7, $8, $9, $10, $11, $12,
			$13, $14, $15, $16,
			$17, $18, $19
		) RETURNING id
	`

	for i := 0; i < batchSize; i++ {
		r := &records[i]
		var exchangeAt, lastTradeAt any
		if !r.ExchangeAt.IsZero() {
			exchangeAt = r.ExchangeAt
		}
		if !r.LastTradeAt.IsZero() {
			lastTradeAt = r.LastTradeAt
		}

		batch.Queue(insertTickSQL,
			r.InstrumentID, r.StreamID, r.Sequence, r.ReceivedAt, exchangeAt, lastTradeAt,
			r.LastPrice, r.AveragePrice, r.OpenPrice, r.HighPrice, r.LowPrice, r.ClosePrice,
			r.LastQuantity, r.Volume, r.TotalBuyQuantity, r.TotalSellQuantity,
			r.OpenInterest, r.OpenInterestHigh, r.OpenInterestLow,
		)
	}

	br := tx.SendBatch(ctx, batch)
	for i := 0; i < batchSize; i++ {
		if err := br.QueryRow().Scan(&tickIDs[i]); err != nil {
			br.Close()
			return fmt.Errorf("failed to scan inserted tick id at batch index %d: %w", i, err)
		}
	}
	if err := br.Close(); err != nil {
		return fmt.Errorf("failed to close tick insert batch: %w", err)
	}

	// 2. High-performance COPY for order depth
	depthSource := NewDepthCopySource(records, tickIDs)
	_, err = tx.CopyFrom(
		ctx,
		pgx.Identifier{"market", "order_depth"},
		[]string{"tick_id", "side", "level", "price", "quantity", "order_count"},
		depthSource,
	)
	if err != nil {
		return fmt.Errorf("failed to copy order depth rows: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed to commit batch transaction: %w", err)
	}

	return nil
}
