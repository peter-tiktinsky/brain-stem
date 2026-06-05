#!/bin/bash
# migration: 0001-sqlite-ddl-v1-to-v2
# min_from: v0.0.0
# applies_at: v1.0.2
#
# Forward-only idempotent migration demonstrator.
#
# Idempotent sqlite DDL: guard on `PRAGMA user_version`; if < 2, run the
# ALTER TABLEs inside a single transaction, then set user_version = 2.
# Converge-if-needed by the version check (re-running against an already-v2 db
# is a structural no-op). Tolerates the oldest/empty precondition: an absent or
# not-yet-created db is a no-op (registry creates the v2 shape lazily on first
# run) — this honors the v0.0.0 legacy-adopt authoring contract.
#
# This is a forward substrate demonstrator: no current defect requires it. The
# sqlite mutation runs inside BEGIN/COMMIT; the upgrade rollback envelope owns the
# whole-file .sqlite(+wal/shm) pre-snapshot. This migration ships only the converge logic.
set -u

CLAUDE_HOME="${CLAUDE_HOME:-}"
DB="${MIGRATION_SQLITE_DB:-$CLAUDE_HOME/governance/manifest.sqlite}"

# Tolerate the oldest/empty precondition (v0.0.0 legacy-adopt): no db yet -> no-op.
if [ -z "$CLAUDE_HOME" ] || [ ! -f "$DB" ]; then
  printf '0001: sqlite db absent (%s) — no-op (lazy-created at v2 shape on first run)\n' "${DB:-<unset>}" >&2
  exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  printf '0001: sqlite3 not on PATH — cannot migrate db; no-op (db untouched)\n' >&2
  exit 0
fi

# --- structural probe: PRAGMA user_version --------------------------------
uv="$(sqlite3 "$DB" 'PRAGMA user_version;' 2>/dev/null || printf '0')"
[ -n "$uv" ] || uv=0
case "$uv" in (*[!0-9]*) uv=0 ;; esac

if [ "$uv" -ge 2 ]; then
  printf '0001: PRAGMA user_version=%s (>=2) — already migrated; converge no-op\n' "$uv" >&2
  exit 0
fi

printf '0001: PRAGMA user_version=%s (<2) — applying v1->v2 DDL in a transaction\n' "$uv" >&2
# Single transaction; bump user_version inside the same BEGIN/COMMIT so the
# probe and the DDL commit atomically. IF NOT EXISTS keeps the ALTER itself
# converge-safe even if a prior partial run added some columns.
sqlite3 "$DB" <<'SQL'
BEGIN;
CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT);
INSERT OR REPLACE INTO schema_meta (key, value) VALUES ('migrated_to', 'v2');
PRAGMA user_version = 2;
COMMIT;
SQL
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '0001: sqlite transaction failed (rc=%s)\n' "$rc" >&2
  exit 1
fi
printf '0001: migrated db to user_version=2\n' >&2
exit 0
