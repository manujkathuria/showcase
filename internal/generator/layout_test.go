package generator

import (
	"testing"
	"unsafe"
)

// TestStructLayout verifies memory footprint, alignment, and field offsets
// according to the go-struct-alignment and go-stack-vs-heap standards.
func TestStructLayout(t *testing.T) {
	// 1. DepthLevel layout
	var dl DepthLevel
	dlSize := unsafe.Sizeof(dl)
	dlAlign := unsafe.Alignof(dl)

	t.Logf("DepthLevel: size=%d bytes, align=%d bytes", dlSize, dlAlign)
	t.Logf("  Offsetof(Price)=%d", unsafe.Offsetof(dl.Price))
	t.Logf("  Offsetof(Quantity)=%d", unsafe.Offsetof(dl.Quantity))
	t.Logf("  Offsetof(OrderCount)=%d", unsafe.Offsetof(dl.OrderCount))
	t.Logf("  Offsetof(Side)=%d", unsafe.Offsetof(dl.Side))
	t.Logf("  Offsetof(Level)=%d", unsafe.Offsetof(dl.Level))

	if dlAlign != 8 {
		t.Errorf("expected DepthLevel alignment 8, got %d", dlAlign)
	}

	// 2. DepthSnapshot layout (5 bids + 5 asks)
	var ds DepthSnapshot
	dsSize := unsafe.Sizeof(ds)
	dsAlign := unsafe.Alignof(ds)
	t.Logf("DepthSnapshot: size=%d bytes (10 levels), align=%d bytes", dsSize, dsAlign)

	if dsSize != 10*dlSize {
		t.Errorf("expected DepthSnapshot size %d (10 * %d), got %d", 10*dlSize, dlSize, dsSize)
	}

	// 3. TickRecord layout
	var tr TickRecord
	trSize := unsafe.Sizeof(tr)
	trAlign := unsafe.Alignof(tr)

	t.Logf("TickRecord: size=%d bytes, align=%d bytes", trSize, trAlign)
	t.Logf("  Offsetof(InstrumentID)=%d", unsafe.Offsetof(tr.InstrumentID))
	t.Logf("  Offsetof(Sequence)=%d", unsafe.Offsetof(tr.Sequence))
	t.Logf("  Offsetof(LastPrice)=%d", unsafe.Offsetof(tr.LastPrice))
	t.Logf("  Offsetof(ReceivedAt)=%d", unsafe.Offsetof(tr.ReceivedAt))
	t.Logf("  Offsetof(StreamID)=%d", unsafe.Offsetof(tr.StreamID))
	t.Logf("  Offsetof(Depth)=%d", unsafe.Offsetof(tr.Depth))

	if trAlign != 8 {
		t.Errorf("expected TickRecord alignment 8, got %d", trAlign)
	}

	// Calculate memory footprint for batch and dataset
	batchCapacity := 1000
	buf := NewBatchBuffer(batchCapacity)
	batchFootprintKB := float64(uintptr(batchCapacity)*trSize) / 1024.0

	t.Logf("BatchBuffer (%d records) heap footprint: %.2f KB", batchCapacity, batchFootprintKB)

	totalRecords := 100_000
	datasetFootprintMB := float64(uintptr(totalRecords)*trSize) / (1024.0 * 1024.0)
	t.Logf("Total 100,000 records footprint: %.2f MB (if fully materialized in memory)", datasetFootprintMB)
	t.Logf("Reusable single batch footprint: %.2f KB (actual resident memory)", batchFootprintKB)

	if buf.Cap() != batchCapacity {
		t.Errorf("expected buffer capacity %d, got %d", batchCapacity, buf.Cap())
	}
}
