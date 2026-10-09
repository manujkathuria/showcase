package generator

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func sampleInstruments(count int) []InstrumentInfo {
	insts := make([]InstrumentInfo, count)
	for i := 0; i < count; i++ {
		insts[i] = InstrumentInfo{
			ID:        int64(i + 1),
			Token:     9910001 + int64(i),
			Symbol:    "SIM_SYNTH_" + string(rune('A'+i)),
			BasePrice: 100000 + int64(i+1)*1000,
		}
	}
	return insts
}

func sampleConfig() Config {
	return Config{
		InstrumentCount:    10,
		TicksPerInstrument: 100,
		StartTime:          time.Date(2026, 10, 9, 9, 15, 0, 0, time.UTC),
		TickInterval:       100 * time.Millisecond,
		Seed:               42,
		StreamID:           uuid.MustParse("c0000000-0000-0000-0000-000000000003"),
		BatchSize:          50,
	}
}

func TestDeterministicGeneration(t *testing.T) {
	cfg := sampleConfig()
	insts := sampleInstruments(cfg.InstrumentCount)

	gen1, err := NewMarketDataGenerator(cfg, insts)
	if err != nil {
		t.Fatalf("unexpected error creating gen1: %v", err)
	}

	gen2, err := NewMarketDataGenerator(cfg, insts)
	if err != nil {
		t.Fatalf("unexpected error creating gen2: %v", err)
	}

	buf1 := NewBatchBuffer(cfg.BatchSize)
	buf2 := NewBatchBuffer(cfg.BatchSize)

	var total1, total2 int64

	for {
		has1 := gen1.NextBatch(buf1)
		has2 := gen2.NextBatch(buf2)

		if has1 != has2 {
			t.Fatalf("batch generation presence mismatch: gen1=%v, gen2=%v", has1, has2)
		}
		if !has1 {
			break
		}

		if buf1.Len() != buf2.Len() {
			t.Fatalf("batch length mismatch: %d vs %d", buf1.Len(), buf2.Len())
		}

		for i := 0; i < buf1.Len(); i++ {
			r1 := buf1.Records[i]
			r2 := buf2.Records[i]

			if r1.Sequence != r2.Sequence || r1.InstrumentID != r2.InstrumentID ||
				!r1.ReceivedAt.Equal(r2.ReceivedAt) || r1.LastPrice != r2.LastPrice {
				t.Fatalf("record mismatch at index %d: %+v vs %+v", i, r1, r2)
			}

			// Verify depth
			for lvl := 0; lvl < 5; lvl++ {
				if r1.Depth.Bids[lvl] != r2.Depth.Bids[lvl] {
					t.Fatalf("bid level %d mismatch at record %d", lvl, i)
				}
				if r1.Depth.Asks[lvl] != r2.Depth.Asks[lvl] {
					t.Fatalf("ask level %d mismatch at record %d", lvl, i)
				}
			}
		}

		total1 += int64(buf1.Len())
		total2 += int64(buf2.Len())
	}

	if total1 != cfg.TotalTicks() || total2 != cfg.TotalTicks() {
		t.Fatalf("expected total ticks %d, got total1=%d, total2=%d", cfg.TotalTicks(), total1, total2)
	}
}

func TestBoundsAndCoherence(t *testing.T) {
	cfg := sampleConfig()
	insts := sampleInstruments(cfg.InstrumentCount)

	gen, err := NewMarketDataGenerator(cfg, insts)
	if err != nil {
		t.Fatalf("NewMarketDataGenerator error: %v", err)
	}

	buf := NewBatchBuffer(cfg.BatchSize)

	for gen.NextBatch(buf) {
		for i, r := range buf.Records {
			if r.Sequence <= 0 {
				t.Errorf("record %d: sequence %d must be > 0", i, r.Sequence)
			}
			if r.LastPrice <= 0 || r.OpenPrice <= 0 || r.HighPrice <= 0 || r.LowPrice <= 0 || r.ClosePrice <= 0 {
				t.Errorf("record %d: prices must be positive, got OHLC=(%d,%d,%d,%d) last=%d",
					i, r.OpenPrice, r.HighPrice, r.LowPrice, r.ClosePrice, r.LastPrice)
			}
			if r.HighPrice < r.OpenPrice || r.HighPrice < r.ClosePrice || r.HighPrice < r.LastPrice {
				t.Errorf("record %d: HighPrice %d is less than Open(%d)/Close(%d)/Last(%d)",
					i, r.HighPrice, r.OpenPrice, r.ClosePrice, r.LastPrice)
			}
			if r.LowPrice > r.OpenPrice || r.LowPrice > r.ClosePrice || r.LowPrice > r.LastPrice {
				t.Errorf("record %d: LowPrice %d is greater than Open(%d)/Close(%d)/Last(%d)",
					i, r.LowPrice, r.OpenPrice, r.ClosePrice, r.LastPrice)
			}
			if r.Volume <= 0 || r.TotalBuyQuantity <= 0 || r.TotalSellQuantity <= 0 {
				t.Errorf("record %d: quantities must be positive", i)
			}
			if r.OpenInterest <= 0 || r.OpenInterestHigh <= 0 || r.OpenInterestLow <= 0 {
				t.Errorf("record %d: open interest must be positive", i)
			}

			// Depth ladder validation
			// 1. Exactly 5 bids and 5 asks
			// 2. Bids strictly descending
			// 3. Asks strictly ascending
			// 4. Spread: bids[0].Price < asks[0].Price
			prevBid := int64(1<<62 - 1)
			for lvl := 0; lvl < 5; lvl++ {
				bid := r.Depth.Bids[lvl]
				if bid.Side != "bid" || bid.Level != int16(lvl+1) {
					t.Errorf("record %d bid %d: invalid side/level: %+v", i, lvl, bid)
				}
				if bid.Price >= prevBid {
					t.Errorf("record %d: bid ladder not strictly descending: prev=%d, curr=%d", i, prevBid, bid.Price)
				}
				if bid.Quantity <= 0 || bid.OrderCount <= 0 {
					t.Errorf("record %d bid %d: quantity/orders must be positive", i, lvl)
				}
				prevBid = bid.Price
			}

			prevAsk := int64(0)
			for lvl := 0; lvl < 5; lvl++ {
				ask := r.Depth.Asks[lvl]
				if ask.Side != "ask" || ask.Level != int16(lvl+1) {
					t.Errorf("record %d ask %d: invalid side/level: %+v", i, lvl, ask)
				}
				if ask.Price <= prevAsk {
					t.Errorf("record %d: ask ladder not strictly ascending: prev=%d, curr=%d", i, prevAsk, ask.Price)
				}
				if ask.Quantity <= 0 || ask.OrderCount <= 0 {
					t.Errorf("record %d ask %d: quantity/orders must be positive", i, lvl)
				}
				prevAsk = ask.Price
			}

			if r.Depth.Bids[0].Price >= r.Depth.Asks[0].Price {
				t.Errorf("record %d: crossed depth: top bid %d >= top ask %d",
					i, r.Depth.Bids[0].Price, r.Depth.Asks[0].Price)
			}
		}
	}
}

func TestBufferReuse(t *testing.T) {
	cfg := sampleConfig()
	cfg.TicksPerInstrument = 1000
	cfg.BatchSize = 250
	insts := sampleInstruments(cfg.InstrumentCount)

	gen, err := NewMarketDataGenerator(cfg, insts)
	if err != nil {
		t.Fatalf("NewMarketDataGenerator error: %v", err)
	}

	buf := NewBatchBuffer(cfg.BatchSize)
	initialCap := buf.Cap()

	var batchCount int
	var totalRecords int64
	var lastSeq int64

	for gen.NextBatch(buf) {
		batchCount++
		totalRecords += int64(buf.Len())

		if buf.Cap() != initialCap {
			t.Errorf("batch buffer capacity grew from %d to %d", initialCap, buf.Cap())
		}

		for _, r := range buf.Records {
			if r.Sequence != lastSeq+1 {
				t.Errorf("sequence gap: expected %d, got %d", lastSeq+1, r.Sequence)
			}
			lastSeq = r.Sequence
		}
	}

	expectedTotal := cfg.TotalTicks()
	if totalRecords != expectedTotal {
		t.Errorf("expected %d records, got %d across %d batches", expectedTotal, totalRecords, batchCount)
	}
}

func BenchmarkGenerateBatch(b *testing.B) {
	cfg := Config{
		InstrumentCount:    10,
		TicksPerInstrument: 100_000,
		StartTime:          time.Date(2026, 10, 9, 9, 15, 0, 0, time.UTC),
		TickInterval:       100 * time.Millisecond,
		Seed:               42,
		StreamID:           uuid.MustParse("c0000000-0000-0000-0000-000000000003"),
		BatchSize:          1000,
	}
	insts := sampleInstruments(cfg.InstrumentCount)

	buf := NewBatchBuffer(cfg.BatchSize)

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		b.StopTimer()
		gen, _ := NewMarketDataGenerator(cfg, insts)
		b.StartTimer()

		for gen.NextBatch(buf) {
			// Consume batch
			_ = buf.Len()
		}
	}
}
