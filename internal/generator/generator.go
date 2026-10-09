package generator

import (
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// Config defines the parameters for synthetic market data generation.
type Config struct {
	InstrumentCount    int
	TicksPerInstrument int
	StartTime          time.Time
	TickInterval       time.Duration
	Seed               int64
	StreamID           uuid.UUID
	BatchSize          int
}

// Validate verifies that generator parameters are within sensible, bounded ranges.
func (c *Config) Validate() error {
	if c.InstrumentCount <= 0 || c.InstrumentCount > 1000 {
		return fmt.Errorf("invalid instrument count %d: must be between 1 and 1000", c.InstrumentCount)
	}
	if c.TicksPerInstrument <= 0 || c.TicksPerInstrument > 1_000_000 {
		return fmt.Errorf("invalid ticks per instrument %d: must be between 1 and 1,000,000", c.TicksPerInstrument)
	}
	if c.StartTime.IsZero() {
		return errors.New("start time must not be zero")
	}
	if c.TickInterval <= 0 {
		return fmt.Errorf("invalid tick interval %v: must be positive", c.TickInterval)
	}
	if c.StreamID == uuid.Nil {
		return errors.New("stream ID must not be nil UUID")
	}
	if c.BatchSize <= 0 || c.BatchSize > 50_000 {
		return fmt.Errorf("invalid batch size %d: must be between 1 and 50,000", c.BatchSize)
	}
	return nil
}

// TotalTicks returns the total number of ticks that will be generated across all instruments.
func (c *Config) TotalTicks() int64 {
	return int64(c.InstrumentCount) * int64(c.TicksPerInstrument)
}

// InstrumentInfo holds catalogue identity mapping for generation.
type InstrumentInfo struct {
	ID        int64
	Token     int64
	Symbol    string
	BasePrice int64
}

// MarketDataGenerator produces deterministic synthetic ticks in bounded batches.
type MarketDataGenerator struct {
	config       Config
	instruments  []InstrumentInfo
	currentStep  int
	currentInst  int
	sequence     int64
	totalTicks   int64
	emittedTicks int64
}

// NewMarketDataGenerator creates a generator instance with initialized instruments.
func NewMarketDataGenerator(cfg Config, instruments []InstrumentInfo) (*MarketDataGenerator, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if len(instruments) != cfg.InstrumentCount {
		return nil, fmt.Errorf("provided %d instruments, config requires %d", len(instruments), cfg.InstrumentCount)
	}

	return &MarketDataGenerator{
		config:       cfg,
		instruments:  instruments,
		currentStep:  0,
		currentInst:  0,
		sequence:     0,
		totalTicks:   cfg.TotalTicks(),
		emittedTicks: 0,
	}, nil
}

// NextBatch fills the provided BatchBuffer with the next batch of generated ticks.
// Returns true if records were added to the buffer, false if generation is complete.
// This function operates with zero per-tick heap allocations after buffer setup by
// directly writing into pre-allocated memory slots (&buf.Records[i]).
func (g *MarketDataGenerator) NextBatch(buf *BatchBuffer) bool {
	buf.Reset()
	if g.emittedTicks >= g.totalTicks {
		return false
	}

	targetCount := buf.Cap()
	if int64(targetCount) > (g.totalTicks - g.emittedTicks) {
		targetCount = int(g.totalTicks - g.emittedTicks)
	}

	// Pre-slice buffer to target count to avoid append re-slice overhead
	buf.Records = buf.Records[:targetCount]

	for i := 0; i < targetCount; i++ {
		inst := g.instruments[g.currentInst]
		step := g.currentStep

		g.sequence++
		g.emittedTicks++

		// Calculate deterministic receive time and source timestamps
		receivedAt := g.config.StartTime.Add(time.Duration(step) * g.config.TickInterval)
		exchangeAt := receivedAt.Add(-15 * time.Millisecond)
		lastTradeAt := receivedAt.Add(-20 * time.Millisecond)

		// Deterministic price calculation (paise scaled integers)
		priceOffset := int64(((step + int(inst.Token)%100) % 50) * 10)
		base := inst.BasePrice
		if base <= 0 {
			base = 100000 + int64(g.currentInst+1)*1000
		}

		lastPrice := base + priceOffset
		openPrice := base
		highPrice := base + 600
		lowPrice := base - 200
		if lowPrice < 100 {
			lowPrice = 100
		}
		if lastPrice > highPrice {
			highPrice = lastPrice + 50
		}
		if lastPrice < lowPrice {
			lowPrice = lastPrice - 50
		}
		avgPrice := (openPrice + highPrice + lowPrice + lastPrice) / 4
		closePrice := base

		lastQty := int64(50 + (step % 200))
		volume := int64(1000 + step*50)
		totalBuyQty := int64(50000 + step*10)
		totalSellQty := int64(48000 + step*10)
		oi := int64(100000 + step*25)
		oiHigh := int64(120000 + step*25)
		oiLow := int64(95000 + step*25)

		// Directly populate pre-allocated struct in buffer slice without value copying
		r := &buf.Records[i]
		r.InstrumentID = inst.ID
		r.InstrumentToken = inst.Token
		r.StreamID = g.config.StreamID
		r.Sequence = g.sequence
		r.ReceivedAt = receivedAt
		r.ExchangeAt = exchangeAt
		r.LastTradeAt = lastTradeAt
		r.LastPrice = lastPrice
		r.AveragePrice = avgPrice
		r.OpenPrice = openPrice
		r.HighPrice = highPrice
		r.LowPrice = lowPrice
		r.ClosePrice = closePrice
		r.LastQuantity = lastQty
		r.Volume = volume
		r.TotalBuyQuantity = totalBuyQty
		r.TotalSellQuantity = totalSellQty
		r.OpenInterest = oi
		r.OpenInterestHigh = oiHigh
		r.OpenInterestLow = oiLow

		// Populate 5 bids (descending below lastPrice)
		for lvl := int16(1); lvl <= 5; lvl++ {
			b := &r.Depth.Bids[lvl-1]
			b.Side = "bid"
			b.Level = lvl
			b.Price = lastPrice - int64(lvl*5)
			b.Quantity = int64(100*int(lvl) + (step % 50))
			b.OrderCount = int64(5 * int(lvl))
		}

		// Populate 5 asks (ascending above lastPrice)
		for lvl := int16(1); lvl <= 5; lvl++ {
			a := &r.Depth.Asks[lvl-1]
			a.Side = "ask"
			a.Level = lvl
			a.Price = lastPrice + int64(lvl*5)
			a.Quantity = int64(100*int(lvl) + (step % 50))
			a.OrderCount = int64(5 * int(lvl))
		}

		// Advance instrument / step counters
		g.currentInst++
		if g.currentInst >= len(g.instruments) {
			g.currentInst = 0
			g.currentStep++
		}
	}

	return len(buf.Records) > 0
}
