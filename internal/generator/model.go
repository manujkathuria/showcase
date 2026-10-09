package generator

import (
	"time"

	"github.com/google/uuid"
)

// DepthLevel represents a single order depth level with raw integer scaling.
// Fields are grouped and aligned to 8-byte boundaries to eliminate internal padding holes.
type DepthLevel struct {
	Price      int64  // Raw scaled integer price (8 bytes, offset 0)
	Quantity   int64  // Nonnegative quantity (8 bytes, offset 8)
	OrderCount int64  // Nonnegative order count (8 bytes, offset 16)
	Side       string // "bid" or "ask" (16 bytes, offset 24)
	Level      int16  // 1 to 5 (2 bytes, offset 40)
	// 6 bytes trailing padding aligns struct to 48 bytes (8-byte boundary)
}

// DepthSnapshot represents the fixed 5-bid and 5-ask market depth snapshot.
// Uses fixed-size arrays to guarantee bounded, allocation-free storage without heap escapes.
type DepthSnapshot struct {
	Bids [5]DepthLevel // 5 * 48 = 240 bytes (offset 0)
	Asks [5]DepthLevel // 5 * 48 = 240 bytes (offset 240)
}

// TickRecord represents a single decoded market quote snapshot.
// Ordered to guarantee 8-byte natural alignment across all scalar, timestamp, and array fields.
type TickRecord struct {
	// 1. Scalar 8-byte integer fields (16 * 8 = 128 bytes, offset 0..128)
	InstrumentID      int64
	InstrumentToken   int64
	Sequence          int64
	LastPrice         int64
	AveragePrice      int64
	OpenPrice         int64
	HighPrice         int64
	LowPrice          int64
	ClosePrice        int64
	LastQuantity      int64
	Volume            int64
	TotalBuyQuantity  int64
	TotalSellQuantity int64
	OpenInterest      int64
	OpenInterestHigh  int64
	OpenInterestLow   int64

	// 2. Timestamp fields (3 * 24 = 72 bytes, offset 128..200)
	// Stored by value (time.Time) to prevent pointer heap escapes. Zero value represents NULL in database.
	ReceivedAt  time.Time
	ExchangeAt  time.Time
	LastTradeAt time.Time

	// 3. UUID stream identifier (16 bytes, offset 200..216)
	StreamID uuid.UUID

	// 4. Embedded depth snapshot (480 bytes, offset 216..696)
	Depth DepthSnapshot
}

// BatchBuffer provides pre-allocated, reusable storage for a batch of TickRecords.
// Allocated once on the heap at setup time, eliminating steady-state allocations.
type BatchBuffer struct {
	Records []TickRecord
}

// NewBatchBuffer allocates a reusable batch buffer with fixed capacity.
func NewBatchBuffer(capacity int) *BatchBuffer {
	if capacity <= 0 {
		capacity = 1000
	}
	return &BatchBuffer{
		Records: make([]TickRecord, 0, capacity),
	}
}

// Reset clears the buffer length for reuse without releasing the underlying allocated capacity.
func (b *BatchBuffer) Reset() {
	b.Records = b.Records[:0]
}

// Len returns the current number of populated records in the buffer.
func (b *BatchBuffer) Len() int {
	return len(b.Records)
}

// Cap returns the maximum allocated capacity of the buffer.
func (b *BatchBuffer) Cap() int {
	return cap(b.Records)
}
