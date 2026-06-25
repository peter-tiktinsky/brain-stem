#!/usr/bin/env bash
# skills/writer-reconciler/process.sh — runtime reconciler for vault writer
# staged packets.
# Per alignment Session 4 + + + +.
# Renamed + reshaped from inbox-processor under Batch B T-11 (2026-05-18).
# Per-tick batch: enumerate ~/.claude/state/vault-staging/<writer-id>/*.json
# packets; per-packet resolve processing rules (folder > file-type-contracts >
# universal pillar 7 default); apply mechanical-only reconciliation
# (winner-pick / dedup / append per R-34); atomic-write destination via
# standard write path; remove processed packet.
# Idempotent: re-running on an empty staging dir is a no-op. Operator-edit
# survivorship preserved via two-signal detection (per Session 4).
# bash 3.2 compatible. jq REQUIRED. shasum REQUIRED.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# T-02 /: the SINGLE canonical ephemeral staging root (.2:74)
# = $CLAUDE_STATE_ROOT/vault-staging (paths.sh exports CLAUDE_STATE_ROOT =
# ~/.local/state/brain-stem). Reconciles the 3-way divergence (was the legacy
# ~/.claude/state/vault-staging) to one value, consistent with render-launchd.sh
# + the cron-wrappers. The durable ~/.local/share/brain-stem/vault-writers/ root
# (manifest.sqlite/daily-processing/raw) stays distinct.
_WR_STATE_ROOT="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}"
DEFAULT_STAGING_ROOT="$_WR_STATE_ROOT/vault-staging"
DEFAULT_RULES_FILE="$REPO_ROOT/governance/vault-writers-rules.json"

STAGING_ROOT=""
DESTINATION_FILTER=""
RULES_FILE="$DEFAULT_RULES_FILE"
AUDIT_LOG=""
DRY_RUN=0

usage() {
  cat <<EOF
process.sh — writer-reconciler runtime.

Usage:
  process.sh [--staging-root PATH] [--destination PATH] [--rules-file PATH]
             [--audit-log PATH] [--dry-run]

Defaults:
  --staging-root           \$STAGING_ROOT env (or $DEFAULT_STAGING_ROOT)
  --rules-file             $DEFAULT_RULES_FILE
  --audit-log              \$CLAUDE_LOG_DIR/writer-reconciler-audit.log
                           (or /tmp/writer-reconciler-audit.log if unset)

Flags:
  --destination PATH       Process only packets whose destination_path
                           matches; useful for explicit flushes via
                           /govern reconcile <destination>.
  --dry-run                Emit reconciliation plan on stdout; no file
                           writes.

Exit codes:
  0   success (or no packets to process)
  2   pre-flight failure
  3   per-packet errors during batch (logged; non-fatal individually)
  4   tick-level error (rules file corrupt; staging root missing in
      strict mode; etc.)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --staging-root)      STAGING_ROOT="$2"; shift 2 ;;
    --destination)       DESTINATION_FILTER="$2"; shift 2 ;;
    --rules-file)        RULES_FILE="$2"; shift 2 ;;
    --audit-log)         AUDIT_LOG="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) printf 'process.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# Resolve defaults: --staging-root argv > $STAGING_ROOT env > built-in default.
if [ -z "$STAGING_ROOT" ]; then
  STAGING_ROOT="${STAGING_ROOT_ENV:-$DEFAULT_STAGING_ROOT}"
fi
if [ -z "$STAGING_ROOT" ]; then
  STAGING_ROOT="$DEFAULT_STAGING_ROOT"
fi

if [ -z "$AUDIT_LOG" ]; then
  AUDIT_LOG="${CLAUDE_LOG_DIR:-/tmp}/writer-reconciler-audit.log"
fi

# ---- pre-flight --------------------------------------------------------------

for tool in jq shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'process.sh: missing prereq: %s\n' "$tool" >&2
    exit 2
  fi
done

if [ ! -d "$STAGING_ROOT" ]; then
  # Missing staging root → silent no-op (the relaxed-timer empty-tick is a cheap
  # early-exit; the StartInterval backstop firing before any writer has emitted
  # a packet is normal — no vault scan, no claude -p; per.2).
  printf 'process.sh: staging root %s does not exist; no-op\n' "$STAGING_ROOT" >&2
  exit 0
fi

# ---- HARD PREREQ: in-process lockf single-instance guard ----------------
# Ported from doc-amender's in-process lockf guard (§Consequences). Under
# WatchPaths bursts, concurrent reconcilers would race the destination mv +
# packet rm → double-write. Re-exec $0 under /usr/bin/lockf -k -t 0 so the whole
# batch runs while holding an exclusive advisory lock; the kernel releases it on
# process death (no stale-lock class). Concurrent fires coalesce (the second
# re-reads the same staging state) or get rc=75 contention → exit 4 advisory.
# Skipped on a no-op tick above (we only lock when there is work to coordinate).
LOCK_FILE="$STAGING_ROOT/.writer-reconciler.lock"
if [ -z "${WRITER_RECONCILER_LOCKED:-}" ]; then
  export WRITER_RECONCILER_LOCKED=1
  inner_args=""
  [ -n "$STAGING_ROOT" ]      && inner_args="$inner_args --staging-root $STAGING_ROOT"
  [ -n "$DESTINATION_FILTER" ] && inner_args="$inner_args --destination $DESTINATION_FILTER"
  [ "$RULES_FILE" != "$DEFAULT_RULES_FILE" ] && inner_args="$inner_args --rules-file $RULES_FILE"
  [ -n "$AUDIT_LOG" ]         && inner_args="$inner_args --audit-log $AUDIT_LOG"
  [ "$DRY_RUN" = "1" ]        && inner_args="$inner_args --dry-run"
  # shellcheck disable=SC2086
  if ! /usr/bin/lockf -k -t 0 "$LOCK_FILE" "$0" $inner_args; then
    rc=$?
    if [ "$rc" = "75" ]; then
      printf 'process.sh: lock contention on %s; another reconciler tick in flight\n' "$LOCK_FILE" >&2
      exit 4
    fi
    exit "$rc"
  fi
  exit 0
fi

# R-52 union-load fallback: the loose vault-writers-rules.json is repo-only
# (composed into the SHIPPED foundation-master bundle; install.sh keeps the 7 pillars unshipped).
# When it is absent/unreadable — a clean adopter, where this cap would otherwise exit 4 — read
# the EFFECTIVE .vault_writers slot through the foundation⊕overlay merger (overlay wins per R-52)
# so the cap reads the canonical merged register, never a raw spoke. The merged slot's top-level
# (.processing_defaults) matches the loose spoke the UNIVERSAL_* jq below expects. Mirrors the
# plans-rules caps; an explicit --rules-file override (present + readable) is preserved.
if [ ! -r "$RULES_FILE" ] || ! jq empty "$RULES_FILE" >/dev/null 2>&1; then
  _OVL="${FOUNDATION_OVERLAY_LOAD:-${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/foundation-overlay-load.sh}"
  [ -x "$_OVL" ] || _OVL="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/hooks/lib/foundation-overlay-load.sh"
  _FM="${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json"
  if [ -x "$_OVL" ] && [ -f "$_FM" ]; then
    _UNION="$(mktemp 2>/dev/null || true)"
    if [ -n "$_UNION" ] && bash "$_OVL" --foundation-path "$_FM" \
          --overlay-path "$(dirname "$_FM")/overlay-master.json" --query '.vault_writers' --force-override > "$_UNION" 2>/dev/null \
          && [ -s "$_UNION" ] && [ "$(head -c4 "$_UNION" 2>/dev/null)" != null ]; then
      RULES_FILE="$_UNION"; trap 'rm -f "$_UNION"' EXIT
    elif [ -n "$_UNION" ]; then rm -f "$_UNION"; fi
  fi
fi

if [ ! -r "$RULES_FILE" ]; then
  printf 'process.sh: rules-file not readable: %s\n' "$RULES_FILE" >&2
  exit 4
fi

if ! jq empty "$RULES_FILE" >/dev/null 2>&1; then
  printf 'process.sh: rules-file is not valid JSON: %s\n' "$RULES_FILE" >&2
  exit 4
fi

# Read universal pillar 7 defaults from rules file. These slots are SCALAR strings
# (.processing_defaults = {"dedup":"sha256-content","survivorship":"operator-edit-wins",
# "merge":"winner-pick"} in both the loose spoke and the foundation-master .vault_writers slot),
# NOT objects — so read the scalar directly. The prior `.dedup.strategy`/`.survivorship.default`/
# `.merge.strategy` paths object-indexed a string (jq rc=5, NOT caught by `//`) -> EMPTY values;
# harmless while writer-reconciler hard-exited on a clean adopter (loose spoke absent), but the
# bypasses the operator-edit-wins preservation gate (~:436) -> operator-data-loss. (
# comprehensive PATTERN-B [HIGH].)
UNIVERSAL_DEDUP=$(jq -r '.processing_defaults.dedup // "content-hash"' "$RULES_FILE")
UNIVERSAL_SURVIVORSHIP=$(jq -r '.processing_defaults.survivorship // "newer-mtime-wins"' "$RULES_FILE")
UNIVERSAL_MERGE=$(jq -r '.processing_defaults.merge // "union-dedupe-by-key"' "$RULES_FILE")

if [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
fi

# ---- helpers ----------------------------------------------------------------

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

audit_emit() {
  # $1 packet-path  $2 writer-id  $3 destination  $4 op  $5 result
  local line
  line=$(jq -nc \
    --arg ts "$(now_utc)" \
    --arg packet "$1" \
    --arg writer_id "$2" \
    --arg destination "$3" \
    --arg op "$4" \
    --arg result "$5" \
    '{ts:$ts,packet:$packet,writer_id:$writer_id,destination:$destination,op:$op,result:$result}')
  if [ "$DRY_RUN" = "0" ]; then
    printf '%s\n' "$line" >> "$AUDIT_LOG"
  else
    printf '[dry-run audit] %s\n' "$line"
  fi
}

# Write a sidecar `_reconciler-error.json` next to a packet describing the
# rejection reason. Packet is retained per Session 4.
sidecar_error() {
  # $1 packet-path  $2 reason
  local packet="$1" reason="$2"
  local sidecar="${packet%.json}._reconciler-error.json"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run sidecar-error] %s: %s\n' "$packet" "$reason"
    return 0
  fi
  jq -nc \
    --arg ts "$(now_utc)" \
    --arg reason "$reason" \
    '{ts:$ts,reason:$reason,retry_eligible:true}' \
    > "$sidecar" 2>/dev/null || true
}

# Walk up from a destination path to find nearest _processing-rules.json.
# Echo the path if found; empty otherwise.
find_folder_rules() {
  # $1 destination-path
  local dest="$1" d
  d=$(dirname "$dest")
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    if [ -r "$d/_processing-rules.json" ]; then
      printf '%s' "$d/_processing-rules.json"
      return 0
    fi
    d=$(dirname "$d")
  done
  return 1
}

# Validate destination-path is within allowed roots: $VAULT_ROOT,
# ~/.claude (librarian-only files), or — when WORK_CONFIGURED=1 — the
# $WORK_HOME/* work-project tree (a Form-B packet keyed on the ~/work/<spoke>
# physical path; canonicalized to the Form-A $VAULT_ROOT/Work/<rest> vault view
# at the call site so supersession stays single-keyed). Returns 0 if allowed;
# 1 otherwise.
destination_within_allowed_roots() {
  # $1 destination-path
  local dest="$1"
  local vault="${VAULT_ROOT:-}"
  local claude_home_dir="${HOME}/.claude"
  local work_home="${WORK_HOME:-}"
  case "$dest" in
    "$vault"/*)
      if [ -n "$vault" ]; then return 0; fi
      ;;
    "$claude_home_dir"/*)
      return 0
      ;;
  esac
  if [ "${WORK_CONFIGURED:-0}" = "1" ] && [ -n "$work_home" ]; then
    case "$dest" in
      "$work_home"/*) return 0 ;;
    esac
  fi
  return 1
}

# Compose effective rules by merging folder > universal (file-type-contracts
# overrides applied per-packet at apply time when destination type matches a
# known contract). Echoes JSON {dedup, survivorship, merge}.
compose_effective_rules() {
  # $1 destination-path
  local dest="$1"
  local folder_rules dedup survivorship merge
  dedup="$UNIVERSAL_DEDUP"
  survivorship="$UNIVERSAL_SURVIVORSHIP"
  merge="$UNIVERSAL_MERGE"
  folder_rules=$(find_folder_rules "$dest" 2>/dev/null || true)
  if [ -n "$folder_rules" ] && [ -r "$folder_rules" ]; then
    if jq empty "$folder_rules" >/dev/null 2>&1; then
      local fr_dedup fr_surv fr_merge
      fr_dedup=$(jq -r '.dedup // empty' "$folder_rules" 2>/dev/null)
      fr_surv=$(jq -r '.survivorship // empty' "$folder_rules" 2>/dev/null)
      fr_merge=$(jq -r '.merge // empty' "$folder_rules" 2>/dev/null)
      if [ -n "$fr_dedup" ]; then dedup="$fr_dedup"; fi
      if [ -n "$fr_surv" ];  then survivorship="$fr_surv"; fi
      if [ -n "$fr_merge" ]; then merge="$fr_merge"; fi
    fi
  fi
  jq -nc \
    --arg dedup "$dedup" \
    --arg survivorship "$survivorship" \
    --arg merge "$merge" \
    '{dedup:$dedup,survivorship:$survivorship,merge:$merge}'
}

# Detect operator edit at destination per Session 4 (two-signal):
# - last_user_edit frontmatter > writer's emitted_at, OR
# - content-hash diff against writer's last-known content_sha256.
# Returns 0 if operator edit detected; 1 otherwise.
operator_edit_detected() {
  # $1 destination-path  $2 packet-emitted_at  $3 packet-content_sha256
  local dest="$1" emitted_at="$2" content_sha="$3"
  if [ ! -f "$dest" ]; then
    return 1
  fi
  # Signal 1: last_user_edit frontmatter.
  if grep -q '^last_user_edit:' "$dest" 2>/dev/null; then
    local lue
    lue=$(grep '^last_user_edit:' "$dest" 2>/dev/null | head -1 | awk -F: '{print $2}' | tr -d ' "')
    if [ -n "$lue" ] && [ "$lue" \> "$emitted_at" ]; then
      return 0
    fi
  fi
  # Signal 2: content-hash drift vs writer's last-known.
  local cur_sha
  cur_sha=$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}')
  if [ -n "$cur_sha" ] && [ "$cur_sha" != "$content_sha" ]; then
    return 0
  fi
  return 1
}

# Step 8.5 + 8.6 helper (per SKILL.md../ spec.md / writer-
# pipeline-layering.md..+../).
# Inputs: destination, writer_id, content_sha, output_type, packet_kind, source_id.
# Behavior:
#   - Step 8.5: append one row to
#     $VAULT_WRITER_STATE_ROOT/daily-processing/$(utc-today)/<dest-slug>.jsonl.
#     Destination-slug derivation: strip leading `/`; replace `/`, ` `, `.`
#     with `_`. Row shape: {ts, packet_sha, writer_id, destination_path,
#     content_sha256, output_type, packet_kind, write_bucket}. Atomic `>>`
#     append (POSIX atomic for sub-PIPE_BUF writes). MPSC discipline:
#     reconciler is the sole writer. Day-rollover immutability via UTC-date
#     filename keying.
#   - Step 8.6: invoke `bash $REPO_ROOT/lib/manifest-record.sh record-write`
#     with derived write_bucket (create | modify-append | modify-amend) +
#     optional --supersedes <prior-active-row-id> in the same library
#     transaction. Best-effort: when manifest not yet bootstrapped (no
#     `init` called; typical in dev/fixture for step-8.5-isolated tests),
#     skip silently — install scaffolding bootstraps in production.
# write_bucket derivation per SKILL.md-129:
#   - 0 prior rows at destination          → "create"
#   - >0 prior rows + packet_kind=amender-replacement → "modify-amend"
#   - else                                 → "modify-append"
# Returns 0 on success or skip-manifest-best-effort; 1 on JSONL write failure
# (hard requirement; step 8.5 row IS the audit signal that the reconciler
# touched the destination).
emit_daily_processing_and_manifest_row() {
  local destination="$1" writer_id="$2" content_sha="$3" output_type="$4" packet_kind="$5" source_id="$6"
  local vault_writer_state_root="${VAULT_WRITER_STATE_ROOT:-$HOME/.local/share/brain-stem/vault-writers}"
  local today daily_dir dest_slug jsonl_file
  today=$(date -u +%Y-%m-%d)
  daily_dir="$vault_writer_state_root/daily-processing/$today"
  dest_slug=$(printf '%s' "$destination" | sed 's|^/||; s|/|_|g; s/ /_/g; s/\./_/g')
  jsonl_file="$daily_dir/$dest_slug.jsonl"

  # Manifest history query (for write_bucket derivation + supersession id).
  # this resolves the divergent process.sh path to the shipped hooks/lib/
  # substrate (T-01 /), reconciling against install.sh:700 hooks/lib/.
  local manifest_record manifest_path
  manifest_record="$REPO_ROOT/hooks/lib/manifest-record.sh"
  manifest_path="${WRITER_MANIFEST_PATH:-$vault_writer_state_root/manifest.sqlite}"
  local write_bucket="create"
  local prior_active_id=""
  if [ -r "$manifest_record" ] && [ -f "$manifest_path" ]; then
    local history
    history=$(bash "$manifest_record" query-destination-history --destination-path "$destination" 2>/dev/null)
    if [ -n "$history" ]; then
      prior_active_id=$(printf '%s\n' "$history" | jq -rs '[.[] | select(.status == "active")] | .[0].id // ""' 2>/dev/null)
      if [ "$packet_kind" = "amender-replacement" ]; then
        write_bucket="modify-amend"
      else
        write_bucket="modify-append"
      fi
    fi
  fi

  # Step 8.5: append daily-processing JSONL row.
  mkdir -p "$daily_dir" 2>/dev/null || return 1
  local row
  row=$(jq -nc \
    --arg ts "$(now_utc)" \
    --arg packet_sha "$content_sha" \
    --arg writer_id "$writer_id" \
    --arg destination_path "$destination" \
    --arg content_sha256 "$content_sha" \
    --arg output_type "$output_type" \
    --arg packet_kind "$packet_kind" \
    --arg write_bucket "$write_bucket" \
    '{ts:$ts,packet_sha:$packet_sha,writer_id:$writer_id,destination_path:$destination_path,content_sha256:$content_sha256,output_type:$output_type,packet_kind:$packet_kind,write_bucket:$write_bucket}')
  printf '%s\n' "$row" >> "$jsonl_file" || return 1

  # Step 8.6: write manifest row (best-effort; skip when manifest not initialized).
  if [ -r "$manifest_record" ] && [ -f "$manifest_path" ]; then
    bash "$manifest_record" record-write \
      --writer-id "$writer_id" \
      --destination-path "$destination" \
      --content-sha256 "$content_sha" \
      --write-bucket "$write_bucket" \
      ${packet_kind:+--packet-kind "$packet_kind"} \
      ${source_id:+--source-id "$source_id"} \
      ${prior_active_id:+--supersedes "$prior_active_id"} \
      >/dev/null 2>&1 || true
  fi
  return 0
}

# Apply a packet to its destination per the resolved rules.
# Returns 0 on success; non-zero on failure.
apply_packet() {
  # $1 packet-path  $2 writer-id
  local packet="$1" writer_id="$2"
  if ! jq empty "$packet" >/dev/null 2>&1; then
    sidecar_error "$packet" "packet-not-valid-json"
    audit_emit "$packet" "$writer_id" "" "parse" "FAIL"
    return 1
  fi
  local destination output_type emitted_at content_sha packet_kind source_id
  destination=$(jq -r '.destination_path // empty' "$packet")
  output_type=$(jq -r '.output_type // empty' "$packet")
  emitted_at=$(jq -r '.emitted_at // empty' "$packet")
  content_sha=$(jq -r '.content_sha256 // empty' "$packet")
  packet_kind=$(jq -r '.packet_kind // "writer-emit"' "$packet")
  source_id=$(jq -r '.source_id // empty' "$packet")
  if [ -z "$destination" ] || [ -z "$output_type" ] || [ -z "$content_sha" ]; then
    sidecar_error "$packet" "packet-missing-required-fields"
    audit_emit "$packet" "$writer_id" "$destination" "parse" "FAIL"
    return 1
  fi
  # Destination filter (--destination flag).
  if [ -n "$DESTINATION_FILTER" ] && [ "$destination" != "$DESTINATION_FILTER" ]; then
    return 0
  fi
  # Allowed-destination check.
  if ! destination_within_allowed_roots "$destination"; then
    sidecar_error "$packet" "destination-outside-allowed-roots"
    audit_emit "$packet" "$writer_id" "$destination" "guard" "REJECT"
    return 1
  fi
  # Canonicalize-on-pass (FIX #5): a Form-B packet keyed on the $WORK_HOME/<rest>
  # physical path is rewritten to the Form-A $VAULT_ROOT/Work/<rest> vault view so
  # supersession (and every downstream rules/write step) keys on a single path. A
  # Form-A packet (already under $VAULT_ROOT/Work/) does NOT match the $WORK_HOME/
  # prefix, so this is idempotent — no double-prefix.
  if [ "${WORK_CONFIGURED:-0}" = "1" ] && [ -n "${WORK_HOME:-}" ] && [ -n "${VAULT_ROOT:-}" ]; then
    case "$destination" in
      "$WORK_HOME"/*)
        destination="$VAULT_ROOT/Work/${destination#"$WORK_HOME"/}"
        ;;
    esac
  fi
  # Compose effective rules.
  local rules survivorship merge
  rules=$(compose_effective_rules "$destination")
  survivorship=$(printf '%s' "$rules" | jq -r '.survivorship')
  merge=$(printf '%s' "$rules" | jq -r '.merge')
  # Operator-edit gate (when survivorship=operator-edit-wins).
  if [ "$survivorship" = "operator-edit-wins" ]; then
    if operator_edit_detected "$destination" "$emitted_at" "$content_sha"; then
      audit_emit "$packet" "$writer_id" "$destination" "survivorship-skip" "OPERATOR-EDIT-PRESERVED"
      if [ "$DRY_RUN" = "0" ]; then
        rm -f "$packet" 2>/dev/null || true
      fi
      return 0
    fi
  fi
  # Dry-run early exit before any filesystem write.
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run apply] packet=%s destination=%s output_type=%s op=write-via-%s\n' \
      "$packet" "$destination" "$output_type" "$merge"
    audit_emit "$packet" "$writer_id" "$destination" "$merge" "DRY-RUN"
    return 0
  fi
  # Atomic write.
  local tmp_dest="$destination.tmp.$$"
  mkdir -p "$(dirname "$destination")" 2>/dev/null || true
  case "$output_type" in
    markdown)
      if ! jq -r '.body' "$packet" > "$tmp_dest" 2>/dev/null; then
        rm -f "$tmp_dest"
        sidecar_error "$packet" "body-write-markdown-failed"
        audit_emit "$packet" "$writer_id" "$destination" "write" "FAIL"
        return 1
      fi
      ;;
    json)
      if ! jq -c '.body' "$packet" > "$tmp_dest" 2>/dev/null; then
        rm -f "$tmp_dest"
        sidecar_error "$packet" "body-write-json-failed"
        audit_emit "$packet" "$writer_id" "$destination" "write" "FAIL"
        return 1
      fi
      ;;
    sqlite|db|opaque)
      if ! jq -r '.body.data // empty' "$packet" \
            | (command -v base64 >/dev/null 2>&1 && base64 -d 2>/dev/null || cat) \
            > "$tmp_dest" 2>/dev/null; then
        rm -f "$tmp_dest"
        sidecar_error "$packet" "body-write-binary-failed"
        audit_emit "$packet" "$writer_id" "$destination" "write" "FAIL"
        return 1
      fi
      ;;
    *)
      rm -f "$tmp_dest"
      sidecar_error "$packet" "unknown-output-type-$output_type"
      audit_emit "$packet" "$writer_id" "$destination" "write" "FAIL"
      return 1
      ;;
  esac
  if ! mv -f "$tmp_dest" "$destination"; then
    rm -f "$tmp_dest"
    sidecar_error "$packet" "atomic-rename-failed"
    audit_emit "$packet" "$writer_id" "$destination" "write" "FAIL"
    return 1
  fi
  rm -f "$packet" 2>/dev/null || true
  # Step 8.5 + 8.6 (per SKILL.md..). JSONL is hard requirement
  # (row IS the audit signal); manifest is best-effort (skip when not
  # bootstrapped; install scaffolding handles in production).
  if ! emit_daily_processing_and_manifest_row \
        "$destination" "$writer_id" "$content_sha" "$output_type" \
        "$packet_kind" "$source_id"; then
    audit_emit "$packet" "$writer_id" "$destination" "manifest" "FAIL"
    return 1
  fi
  audit_emit "$packet" "$writer_id" "$destination" "$merge" "OK"
  return 0
}

# ---- main batch loop --------------------------------------------------------

PROCESSED=0
SUCCEEDED=0
FAILED=0
SKIPPED=0

shopt -s nullglob 2>/dev/null || true
for writer_dir in "$STAGING_ROOT"/*/; do
  [ -d "$writer_dir" ] || continue
  writer_id=$(basename "$writer_dir")
  if [ "$writer_id" = "_archive" ]; then
    continue
  fi
  for packet in "$writer_dir"*.json; do
    [ -f "$packet" ] || continue
    case "$packet" in
      *._reconciler-error.json) continue ;;
    esac
    PROCESSED=$((PROCESSED + 1))
    if apply_packet "$packet" "$writer_id"; then
      SUCCEEDED=$((SUCCEEDED + 1))
    else
      FAILED=$((FAILED + 1))
    fi
  done
done

# ---- summary ----------------------------------------------------------------

printf 'process.sh: processed=%d succeeded=%d failed=%d skipped=%d\n' \
  "$PROCESSED" "$SUCCEEDED" "$FAILED" "$SKIPPED" >&2

if [ "$FAILED" -gt 0 ]; then
  exit 3
fi
exit 0
