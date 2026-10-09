# Verification 002: Tick and depth storage

Date: 2026-10-09

Status: Changes requested. Schema and exercised constraints/permissions pass; query tooling needs corrections before representative-data testing.

Task: [002-market-tick-storage](../tasks/002-market-tick-storage.md)

Implementation: [002-market-tick-storage](../implementation/002-market-tick-storage.md)

## Independent evidence

Ran `infra/db/checks/003_market_tick_storage_checks.sql` as local administrator against `intraday_streaming`: ownership, exercised constraint rejections, and small-fixture query checks passed, ending in ROLLBACK.

Ran `infra/db/checks/005_verify_market_runtime_permissions.sql` with an actual `streaming_app` login: market reads succeeded; writes/DDL and public privileges were denied. It ended in ROLLBACK. Both market tables contained zero persisted rows at this check.

Reviewed migration and query-plan scripts. Representative query performance remains deferred to Task 003; no performance approval is implied by these results.

## Findings for Antigravity

1. **Preserve caller query parameters.** `004_market_query_plans.sql` unconditionally resets all variables with `\set`, so `psql -v instrument_id=...` or a different time range cannot select the generated dataset. Use conditional defaults via `\if :{?variable}`, validate limits, and safely quote timestamp values. Verify two distinct parameter sets affect the executed queries. Add a target-database guard consistent with the other scripts.
2. **Isolate correctness fixtures and assert identities.** `003_market_tick_storage_checks.sql` selects existing catalogue instruments, then queries latest/history without isolating them from recorded data. Loading Task 003 data can make checks fail even when schema behavior is correct. Create dedicated instruments inside the rollback transaction and use the same scoped query contracts as production. Assert exact ordered tick IDs across both pagination pages and history, rather than row counts alone. Include the receive-time lower bound in replay query templates so the half-open range is honored even if a cursor precedes it. Verify completeness for every returned snapshot and independence from enabled subscription configuration.
3. **Correct index documentation.** The implementation report says a composite primary key clusters depth rows on disk and latest lookup uses a single-page scan. An ordinary B-tree primary key does not physically cluster PostgreSQL heap rows, and page accesses must be measured. Describe index support without claiming physical clustering or unmeasured I/O costs.

## Closure criteria

Review the corrections and rerun correctness/permission checks. Verify query parameter overrides and range semantics using small rollback-only fixtures. Record outcomes here; performance measurements on generated data remain a separate Task 003 deliverable.
