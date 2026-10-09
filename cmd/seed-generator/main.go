package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/google/uuid"

	"intraday-trading/internal/db"
	"intraday-trading/internal/generator"
)

func main() {
	var (
		instrumentsFlag = flag.Int("instruments", 10, "Number of synthetic instruments to generate (1-1000)")
		ticksFlag       = flag.Int("ticks-per-instrument", 10000, "Number of ticks per instrument (1-1000000)")
		startTimeStr    = flag.String("start-time", "2026-10-09T09:15:00+05:30", "Simulation start time in RFC3339 format")
		intervalStr     = flag.String("tick-interval", "100ms", "Time step between ticks")
		seedFlag        = flag.Int64("seed", 42, "Pseudo-random seed for deterministic generation")
		streamIDStr     = flag.String("stream-id", "c0000000-0000-0000-0000-000000000003", "Fixed publisher stream UUID")
		batchSizeFlag   = flag.Int("batch-size", 1000, "Batch size for transactional database writes")
		smokeFlag       = flag.Bool("smoke", false, "Smoke test preset: 2 instruments x 50 ticks (100 ticks, 1000 depth rows)")
		analyzeFlag     = flag.Bool("analyze", true, "Run ANALYZE on market tables after successful load")
	)

	flag.Parse()

	if *smokeFlag {
		*instrumentsFlag = 2
		*ticksFlag = 50
		*batchSizeFlag = 50
		*streamIDStr = "c0000000-0000-0000-0000-000000000099"
		log.Println("[INFO] Smoke preset enabled: 2 instruments x 50 ticks = 100 ticks, stream c0000000-0000-0000-0000-000000000099")
	}

	startTime, err := time.Parse(time.RFC3339, *startTimeStr)
	if err != nil {
		log.Fatalf("[ERROR] Invalid start-time %q: %v", *startTimeStr, err)
	}

	interval, err := time.ParseDuration(*intervalStr)
	if err != nil {
		log.Fatalf("[ERROR] Invalid tick-interval %q: %v", *intervalStr, err)
	}

	streamID, err := uuid.Parse(*streamIDStr)
	if err != nil {
		log.Fatalf("[ERROR] Invalid stream-id %q: %v", *streamIDStr, err)
	}

	cfg := generator.Config{
		InstrumentCount:    *instrumentsFlag,
		TicksPerInstrument: *ticksFlag,
		StartTime:          startTime,
		TickInterval:       interval,
		Seed:               *seedFlag,
		StreamID:           streamID,
		BatchSize:          *batchSizeFlag,
	}

	if err := cfg.Validate(); err != nil {
		log.Fatalf("[ERROR] Invalid generator configuration: %v", err)
	}

	// Setup graceful signal context
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	// Load DB config from environment
	dbCfg := db.LoadConfigFromEnv()

	log.Printf("[INFO] Connecting to database %s on %s:%d as user %s...",
		dbCfg.Database, dbCfg.Host, dbCfg.Port, dbCfg.User)

	pool, err := db.Connect(ctx, dbCfg)
	if err != nil {
		log.Fatalf("[ERROR] Database connection failed: %v", err)
	}
	defer pool.Close()

	totalExpectedTicks := cfg.TotalTicks()
	totalExpectedDepth := totalExpectedTicks * 10

	log.Printf("[INFO] Target Dataset: %d instruments x %d ticks = %d ticks (%d depth rows)",
		cfg.InstrumentCount, cfg.TicksPerInstrument, totalExpectedTicks, totalExpectedDepth)
	log.Printf("[INFO] Stream UUID: %s | Time Span: %s to %s",
		cfg.StreamID, cfg.StartTime.Format(time.RFC3339),
		cfg.StartTime.Add(time.Duration(cfg.TicksPerInstrument)*cfg.TickInterval).Format(time.RFC3339))

	// Check if already seeded (idempotency check)
	status, err := db.CheckStreamStatus(ctx, pool, cfg.StreamID, totalExpectedTicks)
	if err != nil {
		log.Fatalf("[ERROR] Stream status check failed: %v", err)
	}

	if status.IsComplete {
		log.Printf("[INFO] Stream %s already exists with %d ticks and %d depth rows. Idempotent skip.",
			cfg.StreamID, status.TickCount, status.DepthCount)
		return
	}

	// Ensure synthetic instruments exist
	log.Printf("[INFO] Verifying / inserting %d synthetic instruments in feed.instruments...", cfg.InstrumentCount)
	instruments, err := db.EnsureSyntheticInstruments(ctx, pool, cfg.InstrumentCount)
	if err != nil {
		log.Fatalf("[ERROR] Failed to ensure synthetic instruments: %v", err)
	}

	// Initialize generator
	gen, err := generator.NewMarketDataGenerator(cfg, instruments)
	if err != nil {
		log.Fatalf("[ERROR] Failed to initialize generator: %v", err)
	}

	// Initialize reusable batch buffer and inserter
	buf := generator.NewBatchBuffer(cfg.BatchSize)
	inserter := db.NewBatchInserter(pool, cfg.BatchSize)

	var committedTicks int64
	var batchNumber int

	startTimeLoad := time.Now()
	var initialMem runtime.MemStats
	runtime.ReadMemStats(&initialMem)

	log.Printf("[INFO] Beginning batched load (batch size = %d ticks)...", cfg.BatchSize)

	for gen.NextBatch(buf) {
		select {
		case <-ctx.Done():
			log.Fatalf("[ERROR] Load cancelled by user signal: committed %d of %d ticks", committedTicks, totalExpectedTicks)
		default:
		}

		batchNumber++
		if err := inserter.InsertBatch(ctx, buf); err != nil {
			log.Fatalf("[ERROR] Failed writing batch %d: %v", batchNumber, err)
		}

		committedTicks += int64(buf.Len())

		if batchNumber%10 == 0 || committedTicks == totalExpectedTicks {
			pct := float64(committedTicks) * 100.0 / float64(totalExpectedTicks)
			log.Printf("[PROGRESS] Committed %d / %d ticks (%.1f%%, %d depth rows)",
				committedTicks, totalExpectedTicks, pct, committedTicks*10)
		}
	}

	elapsed := time.Since(startTimeLoad)
	var finalMem runtime.MemStats
	runtime.ReadMemStats(&finalMem)

	tickRate := float64(committedTicks) / elapsed.Seconds()
	depthRate := float64(committedTicks*10) / elapsed.Seconds()
	heapAllocMB := float64(finalMem.Alloc) / (1024 * 1024)

	fmt.Println()
	fmt.Println("============================================================")
	fmt.Println("             SYNTHETIC SEED LOAD COMPLETED                  ")
	fmt.Println("============================================================")
	fmt.Printf(" Stream ID             : %s\n", cfg.StreamID)
	fmt.Printf(" Instruments           : %d\n", cfg.InstrumentCount)
	fmt.Printf(" Ticks per Instrument  : %d\n", cfg.TicksPerInstrument)
	fmt.Printf(" Total Committed Ticks : %d\n", committedTicks)
	fmt.Printf(" Total Committed Depth : %d\n", committedTicks*10)
	fmt.Printf(" Time Range            : %s to %s\n",
		cfg.StartTime.Format(time.RFC3339),
		cfg.StartTime.Add(time.Duration(cfg.TicksPerInstrument)*cfg.TickInterval).Format(time.RFC3339))
	fmt.Printf(" Batch Size            : %d\n", cfg.BatchSize)
	fmt.Printf(" Elapsed Time          : %v\n", elapsed.Round(time.Millisecond))
	fmt.Printf(" Tick Write Rate       : %.1f ticks/sec\n", tickRate)
	fmt.Printf(" Depth Write Rate      : %.1f depth_rows/sec\n", depthRate)
	fmt.Printf(" Process Heap Alloc    : %.2f MB\n", heapAllocMB)
	fmt.Println("============================================================")

	if *analyzeFlag {
		log.Println("[INFO] Running ANALYZE on market.live_ticks and market.order_depth...")
		_, err := pool.Exec(ctx, "ANALYZE market.live_ticks; ANALYZE market.order_depth;")
		if err != nil {
			log.Printf("[WARN] Failed to run ANALYZE: %v", err)
		} else {
			log.Println("[INFO] Table statistics analyzed successfully.")
		}
	}
}
