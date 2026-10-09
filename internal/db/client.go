package db

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"intraday-trading/internal/generator"
)

// Config holds database connection parameters without storing or logging credentials.
type Config struct {
	Host     string
	Port     int
	Database string
	User     string
	Password string
	ConnStr  string
}

// LoadConfigFromEnv reads connection configuration from environment variables.
func LoadConfigFromEnv() Config {
	port := 5432
	if pStr := os.Getenv("PGPORT"); pStr != "" {
		if p, err := strconv.Atoi(pStr); err == nil && p > 0 {
			port = p
		}
	}

	host := os.Getenv("PGHOST")
	if host == "" {
		host = "localhost"
	}

	dbName := os.Getenv("PGDATABASE")
	if dbName == "" {
		dbName = "intraday_streaming"
	}

	user := os.Getenv("PGUSER")
	if user == "" {
		user = os.Getenv("USER")
	}

	return Config{
		Host:     host,
		Port:     port,
		Database: dbName,
		User:     user,
		Password: os.Getenv("PGPASSWORD"),
	}
}

// BuildConnString formats a PostgreSQL connection URI without logging passwords.
func (c Config) BuildConnString() string {
	if c.ConnStr != "" {
		return c.ConnStr
	}
	if c.Password != "" {
		return fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable",
			c.User, c.Password, c.Host, c.Port, c.Database)
	}
	return fmt.Sprintf("postgres://%s@%s:%d/%s?sslmode=disable",
		c.User, c.Host, c.Port, c.Database)
}

// Connect establishes a connection pool and verifies the database name guard.
func Connect(ctx context.Context, cfg Config) (*pgxpool.Pool, error) {
	poolCfg, err := pgxpool.ParseConfig(cfg.BuildConnString())
	if err != nil {
		return nil, fmt.Errorf("invalid database configuration: %w", err)
	}

	poolCfg.MaxConns = 10
	poolCfg.MinConns = 2
	poolCfg.MaxConnLifetime = 1 * time.Hour
	poolCfg.MaxConnIdleTime = 15 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create connection pool: %w", err)
	}

	// Verify database-name guard
	var currentDB string
	err = pool.QueryRow(ctx, "SELECT current_database()").Scan(&currentDB)
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf("failed to query connected database: %w", err)
	}

	if currentDB != "intraday_streaming" {
		pool.Close()
		return nil, fmt.Errorf("refusing connection: expected database \"intraday_streaming\", connected to %q", currentDB)
	}

	return pool, nil
}

// EnsureSyntheticInstruments ensures the required number of synthetic instruments exist in feed.instruments.
// Fails visibly on conflicting catalogue entries without modifying feed.subscriptions.
func EnsureSyntheticInstruments(ctx context.Context, pool *pgxpool.Pool, count int) ([]generator.InstrumentInfo, error) {
	if count <= 0 || count > 1000 {
		return nil, fmt.Errorf("invalid instrument count %d: must be between 1 and 1000", count)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to begin instrument catalogue transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, "SET LOCAL ROLE streaming_owner;"); err != nil {
		return nil, fmt.Errorf("failed to set role streaming_owner: %w", err)
	}

	instruments := make([]generator.InstrumentInfo, count)

	for i := 1; i <= count; i++ {
		token := int64(9910000 + i)
		symbol := fmt.Sprintf("SIM_SYNTH_%02d", i)
		exchange := "SIM"
		segment := "SIM_EQ"
		instType := "EQ"

		// Check if instrument already exists
		var existingID int64
		var existExchange, existSymbol, existSegment, existType string
		err := tx.QueryRow(ctx, `
			SELECT id, exchange, trading_symbol, segment, instrument_type
			FROM feed.instruments
			WHERE instrument_token = $1 OR (exchange = $2 AND trading_symbol = $3)
		`, token, exchange, symbol).Scan(&existingID, &existExchange, &existSymbol, &existSegment, &existType)

		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("error querying existing instrument for token %d: %w", token, err)
		}

		if err == nil {
			// Validate that existing instrument matches fixture definition exactly
			if existExchange != exchange || existSymbol != symbol || existSegment != segment || existType != instType {
				return nil, fmt.Errorf("incompatible catalogue data for token %d / symbol %s: existing has exchange=%s, symbol=%s, segment=%s, type=%s",
					token, symbol, existExchange, existSymbol, existSegment, existType)
			}
			instruments[i-1] = generator.InstrumentInfo{
				ID:        existingID,
				Token:     token,
				Symbol:    symbol,
				BasePrice: 100000 + int64(i)*1000,
			}
		} else {
			// Insert missing synthetic instrument
			var newID int64
			err = tx.QueryRow(ctx, `
				INSERT INTO feed.instruments (instrument_token, exchange, trading_symbol, segment, instrument_type, expiry)
				VALUES ($1, $2, $3, $4, $5, NULL)
				RETURNING id
			`, token, exchange, symbol, segment, instType).Scan(&newID)
			if err != nil {
				return nil, fmt.Errorf("failed to insert synthetic instrument %s: %w", symbol, err)
			}
			instruments[i-1] = generator.InstrumentInfo{
				ID:        newID,
				Token:     token,
				Symbol:    symbol,
				BasePrice: 100000 + int64(i)*1000,
			}
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("failed to commit instrument catalogue changes: %w", err)
	}

	return instruments, nil
}
