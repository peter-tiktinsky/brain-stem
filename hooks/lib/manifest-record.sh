#!/usr/bin/env bash
# hooks/lib/manifest-record.sh — shared library for direct-write skills and the
# writer-reconciler to bootstrap + insert + query rows in the writer manifest
# SQLite substrate at $WRITER_MANIFEST_PATH (default
# $VAULT_WRITER_STATE_ROOT/manifest.sqlite).
#
# Ported from the lib/manifest-record.sh (TOP-LEVEL lib/);
# RELOCATED to hooks/lib/ per (brain-stem has no top-level lib/).:
# the VAULT_WRITER_STATE_ROOT default resolves under ~/.local/share/brain-stem
# (NOT the's ~/.local/share/). The DDL companion
# manifest-migrate.sql resolves via this lib's own SCRIPT_DIR (now hooks/lib/).
# T-01 (writer-pipeline substrate).
#
# OUTPUT CONTRACT:
#   Files written: manifest.sqlite (init applies the manifest-migrate.sql DDL —
#     a 12-field `writes` table + WAL journal + 4 indexes); record-write inserts
#     one active row (+ optional supersession UPDATE) in a single transaction.
#   Row contract: 12 fields mirror schemas/writer-manifest-schema.json ::
#     writes.items.properties exactly (id, writer_id, destination_path,
#     ingestion_date, source_id, content_sha256, raw_path, status,
#     superseded_by, write_bucket, packet_kind, notes).
#   Pre-write validation: required-flag presence, write_bucket + packet_kind
#     enums (mirror the schema CHECK constraints), filename-safe writer-id,
#     manifest-initialized check; prereqs (sqlite3, jq, shasum).
#   Failure mode: BLOCK-AND-LOG — bad invocation / pre-flight failure / lock
#     contention / sqlite operation failure / query-miss all exit non-zero with
#     a diagnostic; the BEGIN/INSERT/UPDATE/COMMIT is atomic (partial failure
#     never leaves a dangling active+active pair on the same destination).
#
# Subcommands (first positional argv):
#   init                        Bootstrap manifest.sqlite via the DDL migration
#                               (idempotent via PRAGMA user_version=1).
#   record-write                Insert new active row; optional supersession
#                               UPDATE on a predecessor row id (atomic txn).
#                               Emits new row id on stdout.
#   query-last-run              Emit MAX(ingestion_date) for a writer_id where
#                               status='active' (the dormant-writer signal
#                               writers-health-audit queries).
#   query-destination-history   Emit NDJSON history for a destination_path
#                               (ORDER BY ingestion_date DESC).
#   query-row                   Emit single JSON row by id (rc=6 if not found).
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`, no `${var,,}`).
# Canonical lock pattern: /usr/bin/lockf -k -t 0 (kernel-backed; not flock).

set -u

# ---- defaults ---------------------------------------------------------------

# Resolve VAULT_WRITER_STATE_ROOT: env wins; otherwise the durable State-tier
# root under ~/.local/share/brain-stem (XDG_DATA_HOME tier). This is the DURABLE
# root (manifest.sqlite/daily-processing/raw), distinct from the EPHEMERAL
# vault-staging root (canonical/State-tier two-root).
if [ -z "${VAULT_WRITER_STATE_ROOT:-}" ]; then
  VAULT_WRITER_STATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/brain-stem/vault-writers"
fi

# Resolve WRITER_MANIFEST_PATH: env wins; otherwise default under
# $VAULT_WRITER_STATE_ROOT.
if [ -z "${WRITER_MANIFEST_PATH:-}" ]; then
  WRITER_MANIFEST_PATH="${VAULT_WRITER_STATE_ROOT}/manifest.sqlite"
fi

SUBCOMMAND=""
WRITER_ID=""
DESTINATION_PATH=""
CONTENT_SHA256=""
WRITE_BUCKET=""
SOURCE_ID=""
RAW_PATH=""
PACKET_KIND=""
NOTES=""
ROW_ID=""
SUPERSEDES_ID=""

usage() {
  cat <<EOF
manifest-record.sh — writer-manifest SQLite substrate library.

Usage:
  manifest-record.sh init
  manifest-record.sh record-write
        --writer-id <id>
        --destination-path <path>
        --content-sha256 <sha>
        --write-bucket <create|modify-append|modify-amend>
        [--source-id <id>]
        [--raw-path <path>]
        [--packet-kind <writer-emit|amender-replacement|amender-conflict>]
        [--notes <text>]
        [--id <row-id>]
        [--supersedes <predecessor-row-id>]
  manifest-record.sh query-last-run --writer-id <id>
  manifest-record.sh query-destination-history --destination-path <path>
  manifest-record.sh query-row --id <row-id>

Subcommands:
  init                       Apply manifest-migrate.sql DDL to
                             \$WRITER_MANIFEST_PATH; idempotent via
                             PRAGMA user_version=1 checkpoint.
  record-write               Insert new active row + optional supersession
                             UPDATE in a single transaction; emits new row id
                             on stdout.
  query-last-run             Emit ISO-8601 date-time of MAX(ingestion_date)
                             for active rows by writer_id (empty if none).
  query-destination-history  Emit NDJSON history (id, writer_id,
                             ingestion_date, content_sha256, status,
                             superseded_by, write_bucket) for a
                             destination_path; ORDER BY ingestion_date DESC.
  query-row                  Emit single JSON object for a row id; rc=6 on
                             not-found.

Env:
  WRITER_MANIFEST_PATH      Default \$VAULT_WRITER_STATE_ROOT/manifest.sqlite.
  VAULT_WRITER_STATE_ROOT   Default ~/.local/share/brain-stem/vault-writers.

Exit codes:
  0   success
  2   bad invocation / missing prereq
  3   pre-flight failure (db unreachable, enum invalid, etc.)
  4   lock contention
  5   sqlite operation failure (BEGIN/COMMIT failed, schema mismatch, etc.)
  6   query miss (query-row found nothing)
EOF
}

# ---- argv parsing -----------------------------------------------------------

if [ $# -lt 1 ]; then
  usage >&2
  exit 2
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  init|record-write|query-last-run|query-destination-history|query-row) : ;;
  -h|--help) usage; exit 0 ;;
  *)
    printf 'manifest-record.sh: unknown subcommand: %s\n' "$SUBCOMMAND" >&2
    usage >&2
    exit 2
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --writer-id)         WRITER_ID="$2"; shift 2 ;;
    --destination-path)  DESTINATION_PATH="$2"; shift 2 ;;
    --content-sha256)    CONTENT_SHA256="$2"; shift 2 ;;
    --write-bucket)      WRITE_BUCKET="$2"; shift 2 ;;
    --source-id)         SOURCE_ID="$2"; shift 2 ;;
    --raw-path)          RAW_PATH="$2"; shift 2 ;;
    --packet-kind)       PACKET_KIND="$2"; shift 2 ;;
    --notes)             NOTES="$2"; shift 2 ;;
    --id)                ROW_ID="$2"; shift 2 ;;
    --supersedes)        SUPERSEDES_ID="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)
      printf 'manifest-record.sh: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ---- shared pre-flight (prereqs + parent dir) -------------------------------

for tool in sqlite3 jq shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'manifest-record.sh: missing prereq: %s\n' "$tool" >&2
    exit 3
  fi
done

MANIFEST_DIR=$(dirname "$WRITER_MANIFEST_PATH")
mkdir -p "$MANIFEST_DIR" 2>/dev/null || {
  printf 'manifest-record.sh: cannot create manifest parent dir: %s\n' "$MANIFEST_DIR" >&2
  exit 3
}

LOCK_FILE="${WRITER_MANIFEST_PATH}.lock"

# Resolve migration script path relative to this script (hooks/lib/).
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MIGRATE_SQL="${SCRIPT_DIR}/manifest-migrate.sql"

# ---- subcommand: init -------------------------------------------------------

if [ "$SUBCOMMAND" = "init" ]; then
  if [ ! -r "$MIGRATE_SQL" ]; then
    printf 'manifest-record.sh: migration script not readable: %s\n' "$MIGRATE_SQL" >&2
    exit 3
  fi

  # Idempotency checkpoint: if the DB already exists and user_version >= 1,
  # the migration has been applied; second invocation is a no-op.
  if [ -f "$WRITER_MANIFEST_PATH" ]; then
    CURRENT_VERSION=$(sqlite3 "$WRITER_MANIFEST_PATH" 'PRAGMA user_version;' 2>/dev/null || echo "")
    if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" -ge 1 ] 2>/dev/null; then
      printf 'manifest-record.sh: init no-op (user_version=%s already applied): %s\n' \
        "$CURRENT_VERSION" "$WRITER_MANIFEST_PATH" >&2
      exit 0
    fi
  fi

  # stdout silenced: PRAGMA results (journal_mode=WAL prints "wal") are not
  # caller-facing output — they leaked as a naked line in install transcripts.
  if ! sqlite3 "$WRITER_MANIFEST_PATH" < "$MIGRATE_SQL" >/dev/null 2>&1; then
    printf 'manifest-record.sh: init failed applying migration: %s\n' "$MIGRATE_SQL" >&2
    exit 5
  fi

  printf 'manifest-record.sh: init applied to %s\n' "$WRITER_MANIFEST_PATH" >&2
  exit 0
fi

# ---- subcommand: query-last-run --------------------------------------------

if [ "$SUBCOMMAND" = "query-last-run" ]; then
  if [ -z "$WRITER_ID" ]; then
    printf 'manifest-record.sh: query-last-run requires --writer-id\n' >&2
    exit 2
  fi
  if [ ! -f "$WRITER_MANIFEST_PATH" ]; then
    printf 'manifest-record.sh: manifest not initialized: %s (run `init` first)\n' \
      "$WRITER_MANIFEST_PATH" >&2
    exit 3
  fi

  # WAL-safe read; no lock required. Empty result -> empty stdout line.
  RESULT=$(sqlite3 "$WRITER_MANIFEST_PATH" \
    "SELECT MAX(ingestion_date) FROM writes WHERE writer_id='${WRITER_ID//\'/\'\'}' AND status='active' GROUP BY writer_id;" \
    2>/dev/null)
  RC=$?
  if [ "$RC" != "0" ]; then
    printf 'manifest-record.sh: query-last-run sqlite error\n' >&2
    exit 5
  fi
  printf '%s\n' "$RESULT"
  exit 0
fi

# ---- subcommand: query-destination-history ---------------------------------

if [ "$SUBCOMMAND" = "query-destination-history" ]; then
  if [ -z "$DESTINATION_PATH" ]; then
    printf 'manifest-record.sh: query-destination-history requires --destination-path\n' >&2
    exit 2
  fi
  if [ ! -f "$WRITER_MANIFEST_PATH" ]; then
    printf 'manifest-record.sh: manifest not initialized: %s (run `init` first)\n' \
      "$WRITER_MANIFEST_PATH" >&2
    exit 3
  fi

  # Use SQLite -separator with NULL-safe coalesce; emit NDJSON via jq composition
  # of column array per row. Avoids embedded-quote escaping risks in -json mode
  # on older sqlite3 builds.
  DP_ESC=$(printf '%s' "$DESTINATION_PATH" | sed "s/'/''/g")
  RAW=$(sqlite3 -separator $'\x1f' "$WRITER_MANIFEST_PATH" \
    "SELECT id, writer_id, ingestion_date, content_sha256, status, COALESCE(superseded_by,''), write_bucket FROM writes WHERE destination_path='${DP_ESC}' ORDER BY ingestion_date DESC;" \
    2>/dev/null)
  RC=$?
  if [ "$RC" != "0" ]; then
    printf 'manifest-record.sh: query-destination-history sqlite error\n' >&2
    exit 5
  fi

  # Empty result -> empty stdout (no rows to emit).
  if [ -z "$RAW" ]; then
    exit 0
  fi

  # Per-row NDJSON composition via jq -R/-c. Field order matches SELECT.
  printf '%s\n' "$RAW" | while IFS=$'\x1f' read -r id writer_id ingestion_date content_sha256 status superseded_by write_bucket; do
    jq -nc \
      --arg id "$id" \
      --arg writer_id "$writer_id" \
      --arg ingestion_date "$ingestion_date" \
      --arg content_sha256 "$content_sha256" \
      --arg status "$status" \
      --arg superseded_by "$superseded_by" \
      --arg write_bucket "$write_bucket" \
      '{
        id: $id,
        writer_id: $writer_id,
        ingestion_date: $ingestion_date,
        content_sha256: $content_sha256,
        status: $status,
        superseded_by: (if $superseded_by == "" then null else $superseded_by end),
        write_bucket: $write_bucket
      }'
  done
  exit 0
fi

# ---- subcommand: query-row --------------------------------------------------

if [ "$SUBCOMMAND" = "query-row" ]; then
  if [ -z "$ROW_ID" ]; then
    printf 'manifest-record.sh: query-row requires --id\n' >&2
    exit 2
  fi
  if [ ! -f "$WRITER_MANIFEST_PATH" ]; then
    printf 'manifest-record.sh: manifest not initialized: %s (run `init` first)\n' \
      "$WRITER_MANIFEST_PATH" >&2
    exit 3
  fi

  ID_ESC=$(printf '%s' "$ROW_ID" | sed "s/'/''/g")
  RAW=$(sqlite3 -separator $'\x1f' "$WRITER_MANIFEST_PATH" \
    "SELECT id, writer_id, destination_path, ingestion_date, COALESCE(source_id,''), content_sha256, COALESCE(raw_path,''), status, COALESCE(superseded_by,''), write_bucket, COALESCE(packet_kind,''), COALESCE(notes,'') FROM writes WHERE id='${ID_ESC}';" \
    2>/dev/null)
  RC=$?
  if [ "$RC" != "0" ]; then
    printf 'manifest-record.sh: query-row sqlite error\n' >&2
    exit 5
  fi

  if [ -z "$RAW" ]; then
    exit 6
  fi

  # Single-row JSON object. NULL passthrough: empty string -> null in JSON
  # for the optional columns. Required columns always present.
  IFS=$'\x1f' read -r id writer_id destination_path ingestion_date source_id content_sha256 raw_path status superseded_by write_bucket packet_kind notes <<EOF_ROW
$RAW
EOF_ROW
  jq -nc \
    --arg id "$id" \
    --arg writer_id "$writer_id" \
    --arg destination_path "$destination_path" \
    --arg ingestion_date "$ingestion_date" \
    --arg source_id "$source_id" \
    --arg content_sha256 "$content_sha256" \
    --arg raw_path "$raw_path" \
    --arg status "$status" \
    --arg superseded_by "$superseded_by" \
    --arg write_bucket "$write_bucket" \
    --arg packet_kind "$packet_kind" \
    --arg notes "$notes" \
    '{
      id: $id,
      writer_id: $writer_id,
      destination_path: $destination_path,
      ingestion_date: $ingestion_date,
      source_id: (if $source_id == "" then null else $source_id end),
      content_sha256: $content_sha256,
      raw_path: (if $raw_path == "" then null else $raw_path end),
      status: $status,
      superseded_by: (if $superseded_by == "" then null else $superseded_by end),
      write_bucket: $write_bucket,
      packet_kind: (if $packet_kind == "" then null else $packet_kind end),
      notes: (if $notes == "" then null else $notes end)
    }'
  exit 0
fi

# ---- subcommand: record-write ----------------------------------------------
#
# Beyond this point, SUBCOMMAND == "record-write". Validate required flags,
# enums, manifest presence; acquire per-database lockf; BEGIN/INSERT/UPDATE/
# COMMIT atomic transaction; emit new row id on stdout.

if [ "$SUBCOMMAND" != "record-write" ]; then
  # Defensive — should be unreachable because the dispatch above exhausts
  # the subcommand enum.
  printf 'manifest-record.sh: internal dispatch error: %s\n' "$SUBCOMMAND" >&2
  exit 2
fi

# ---- record-write: argv validation -----------------------------------------

if [ -z "$WRITER_ID" ]; then
  printf 'manifest-record.sh: record-write requires --writer-id\n' >&2; exit 2
fi
if [ -z "$DESTINATION_PATH" ]; then
  printf 'manifest-record.sh: record-write requires --destination-path\n' >&2; exit 2
fi
if [ -z "$CONTENT_SHA256" ]; then
  printf 'manifest-record.sh: record-write requires --content-sha256\n' >&2; exit 2
fi
if [ -z "$WRITE_BUCKET" ]; then
  printf 'manifest-record.sh: record-write requires --write-bucket\n' >&2; exit 2
fi

# Validate writer-id is filename-safe (mirror staging-emit.sh check; serves
# as defense-in-depth for any caller that derives filesystem paths from it).
case "$WRITER_ID" in
  */*|.*)
    printf 'manifest-record.sh: --writer-id must be filename-safe (got: %s)\n' "$WRITER_ID" >&2
    exit 2
    ;;
esac

# Validate write_bucket enum (mirror schema CHECK constraint).
case "$WRITE_BUCKET" in
  create|modify-append|modify-amend) : ;;
  *)
    printf 'manifest-record.sh: --write-bucket must be one of: create, modify-append, modify-amend (got: %s)\n' \
      "$WRITE_BUCKET" >&2
    exit 3
    ;;
esac

# Validate packet_kind enum if provided (mirror schema CHECK constraint).
if [ -n "$PACKET_KIND" ]; then
  case "$PACKET_KIND" in
    writer-emit|amender-replacement|amender-conflict) : ;;
    *)
      printf 'manifest-record.sh: --packet-kind must be one of: writer-emit, amender-replacement, amender-conflict (got: %s)\n' \
        "$PACKET_KIND" >&2
      exit 3
      ;;
  esac
fi

# Ensure manifest has been initialized.
if [ ! -f "$WRITER_MANIFEST_PATH" ]; then
  printf 'manifest-record.sh: manifest not initialized: %s (run `init` first)\n' \
    "$WRITER_MANIFEST_PATH" >&2
  exit 3
fi

# ---- record-write: lock acquisition (re-exec under lockf) -------------------
#
# Sentinel pattern: outer call (no sentinel) re-execs $0 under lockf and
# forwards original argv inside the lock. Inner call (sentinel set) proceeds
# with the BEGIN/INSERT/UPDATE/COMMIT transaction. Kernel releases the lock
# on inner-process death automatically.

if [ -z "${MANIFEST_RECORD_LOCKED:-}" ]; then
  export MANIFEST_RECORD_LOCKED=1
  if ! /usr/bin/lockf -k -t 0 "$LOCK_FILE" "$0" \
       record-write \
       --writer-id "$WRITER_ID" \
       --destination-path "$DESTINATION_PATH" \
       --content-sha256 "$CONTENT_SHA256" \
       --write-bucket "$WRITE_BUCKET" \
       ${SOURCE_ID:+--source-id "$SOURCE_ID"} \
       ${RAW_PATH:+--raw-path "$RAW_PATH"} \
       ${PACKET_KIND:+--packet-kind "$PACKET_KIND"} \
       ${NOTES:+--notes "$NOTES"} \
       ${ROW_ID:+--id "$ROW_ID"} \
       ${SUPERSEDES_ID:+--supersedes "$SUPERSEDES_ID"}; then
    rc=$?
    if [ "$rc" = "75" ]; then
      printf 'manifest-record.sh: lock contention on %s; deferring\n' "$LOCK_FILE" >&2
      exit 4
    fi
    exit "$rc"
  fi
  exit 0
fi

# ---- record-write: id generation -------------------------------------------
#
# If caller did not supply --id, generate a composite content-hash id:
#   <writer-id>-<destination-sha8>-<emitted-at-s>-<pid>
# Deterministic per writer + destination + timestamp; collision-resistant in
# practice (the lockf serializes the only collision window).

INGESTION_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ -z "$ROW_ID" ]; then
  DEST_SHA=$(printf '%s' "$DESTINATION_PATH" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,8)}')
  if [ -z "$DEST_SHA" ]; then
    printf 'manifest-record.sh: destination-path sha generation failed\n' >&2
    exit 3
  fi
  NOW_NS=$(date -u +%s 2>/dev/null)
  ROW_ID="${WRITER_ID}-${DEST_SHA}-${NOW_NS}-$$"
fi

# ---- record-write: SQL composition (single transaction) ---------------------

ID_ESC=$(printf '%s' "$ROW_ID" | sed "s/'/''/g")
WID_ESC=$(printf '%s' "$WRITER_ID" | sed "s/'/''/g")
DP_ESC=$(printf '%s' "$DESTINATION_PATH" | sed "s/'/''/g")
ING_ESC=$(printf '%s' "$INGESTION_DATE" | sed "s/'/''/g")
SHA_ESC=$(printf '%s' "$CONTENT_SHA256" | sed "s/'/''/g")
WB_ESC=$(printf '%s' "$WRITE_BUCKET" | sed "s/'/''/g")

# Optional columns: NULL when empty, escaped string otherwise.
if [ -n "$SOURCE_ID" ]; then
  SID_SQL="'$(printf '%s' "$SOURCE_ID" | sed "s/'/''/g")'"
else
  SID_SQL="NULL"
fi
if [ -n "$RAW_PATH" ]; then
  RP_SQL="'$(printf '%s' "$RAW_PATH" | sed "s/'/''/g")'"
else
  RP_SQL="NULL"
fi
if [ -n "$PACKET_KIND" ]; then
  PK_SQL="'$(printf '%s' "$PACKET_KIND" | sed "s/'/''/g")'"
else
  PK_SQL="NULL"
fi
if [ -n "$NOTES" ]; then
  NOTES_SQL="'$(printf '%s' "$NOTES" | sed "s/'/''/g")'"
else
  NOTES_SQL="NULL"
fi

# Supersession UPDATE: only emitted when --supersedes provided. Predecessor
# is marked status='superseded' + superseded_by=<new-row-id> in the same
# transaction as the INSERT so partial-failure cannot leave a dangling
# active+active pair on the same destination.
SUPERSESSION_SQL=""
if [ -n "$SUPERSEDES_ID" ]; then
  SUP_ESC=$(printf '%s' "$SUPERSEDES_ID" | sed "s/'/''/g")
  SUPERSESSION_SQL="UPDATE writes SET status='superseded', superseded_by='${ID_ESC}' WHERE id='${SUP_ESC}';"
fi

# Compose the full BEGIN/INSERT/(UPDATE)/COMMIT transaction.
SQL_TXN=$(cat <<EOF_SQL
BEGIN TRANSACTION;
INSERT INTO writes (
  id, writer_id, destination_path, ingestion_date, source_id,
  content_sha256, raw_path, status, superseded_by, write_bucket,
  packet_kind, notes
) VALUES (
  '${ID_ESC}', '${WID_ESC}', '${DP_ESC}', '${ING_ESC}', ${SID_SQL},
  '${SHA_ESC}', ${RP_SQL}, 'active', NULL, '${WB_ESC}',
  ${PK_SQL}, ${NOTES_SQL}
);
${SUPERSESSION_SQL}
COMMIT;
EOF_SQL
)

# Apply transaction. sqlite3 returns non-zero on any failure (CHECK violation,
# PK collision, predecessor missing, etc.); rollback is implicit on error
# because the BEGIN never reached COMMIT.
SQL_ERR=$(printf '%s\n' "$SQL_TXN" | sqlite3 "$WRITER_MANIFEST_PATH" 2>&1)
RC=$?
if [ "$RC" != "0" ]; then
  printf 'manifest-record.sh: record-write transaction failed: %s\n' "$SQL_ERR" >&2
  exit 5
fi

# Emit the new row id on stdout for caller chaining (supersede chains, audit
# log refs, etc.).
printf '%s\n' "$ROW_ID"
exit 0
