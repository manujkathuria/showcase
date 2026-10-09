# Task 004: Database performance baseline and evidence-driven tuning

Status: Planned. Depends on reviewed Task 002 query scripts and verified Task 003 generator/data. Do not execute as part of Task 003.

## Objective

Measure tick/depth database reads and batched writes, identify bottlenecks, and evaluate targeted improvements while preserving schema constraints, complete snapshots, and runtime permissions.

## Baseline

- Use Task 003's reproducible dataset and record its parameters, actual row counts, IDs, and time range. Start with 100,000 ticks and 1 million depth rows; enlarge only when baseline findings justify it.
- Record PostgreSQL version, hardware, relevant settings, indexes, table/index sizes, batch configuration, and cache conditions.
- Run ANALYZE and parameterized `EXPLAIN (ANALYZE, BUFFERS)` for latest tick, instrument history, keyset replay, depth retrieval, and replay with complete depth.
- Exercise selective and broader ranges. Record actual rows, planning/execution times, buffer hits/reads, scan types, sorts, and a small number of repeated runs. Do not equate planner cost units with elapsed time.
- Benchmark writes separately using isolated synthetic stream identities; measure committed ticks and depth rows, throughput, elapsed time, and batch size. Keep correctness checks active. Do not mix baseline datasets or delete existing recordings.

## Improvements

Use measured evidence to choose experiments, such as batch-size changes, insert/COPY strategies, or index changes. Compare one consequential variable at a time with the same workload and preserve reproducible before/after results.

An index adds storage and write cost; retain it for demonstrated query value. A sequential scan may be correct for broad ranges. Do not force scans to manufacture favorable evidence. Do not weaken constraints, durability, or snapshot atomicity for throughput.

Use isolated experiments for potentially disruptive changes. Persistent schema changes require versioned migrations and review; major changes such as hypertables, retention, or compression need an agreed design. Report recommendations as proposals until authorized.

## Deliverables

- Reproducible measurement commands/scripts and captured query plans.
- `docs/implementation/004-database-performance.md` with baseline, experiments, measured results, retained changes, and limitations. No invented service-level targets or end-to-end streaming claims.
- Rerun relevant correctness/permission checks after retained changes; independent verification belongs in a separate review record.

No cloud provisioning, live market integration, WebSocket server, or commits/tags/pushes without a separate request.
