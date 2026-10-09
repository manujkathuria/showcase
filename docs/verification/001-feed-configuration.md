# Verification 001: Feed configuration tables

Date: 2026-10-09

Status: Changes requested. Current database checks pass, but review findings remain open. This task is not yet approved for a completion tag.

Task: [001-feed-configuration](../tasks/001-feed-configuration.md)

Implementation report: [001-feed-configuration](../implementation/001-feed-configuration.md)

## Independent verification

Executed `infra/db/checks/001_verify_constraints.sql` against `intraday_streaming` using an administrator connection. Table existence, schema placement, ownership, and the exercised constraint cases passed. The script completed with ROLLBACK.

Executed `infra/db/checks/002_verify_runtime_permissions.sql` through an actual `streaming_app` login using local credentials. The read query succeeded; attempted writes and table creation were denied. The script completed with ROLLBACK.

Both queries returned tokens `9900001` and `9900002` in `full` mode. A separate read-only query confirmed `current_user = streaming_app` and `has_schema_privilege(current_user, 'public', 'USAGE') = false`.

Migration rerun and seed conflict/repeatability claims in the implementation report were reviewed in code but not independently re-executed in this pass.

## Open findings

1. Add an explicit target-database guard before migration and seed mutations. Commands select the intended database, but scripts do not enforce it.
2. Add executable assertions for enabled-subscription query results, including exclusion of disabled rows. Printing results alone is not verification of query semantics.
3. Assert the runtime user and denied public-schema USAGE inside the permissions script. Denied CREATE alone does not establish denied USAGE.

## Closure

After changes, review the updated scripts and rerun the relevant checks. Record observed outcomes here before marking the task verified and creating its completion tag. Keep credentials out of verification output.
