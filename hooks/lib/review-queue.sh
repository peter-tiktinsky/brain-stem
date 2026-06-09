# hooks/lib/review-queue.sh — memory-review producer API.
# Source this file — do not execute it.
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/review-queue.sh"
#   enqueue_item <item-json>
# The guaranteed-surfacing + persistent-reminder substrate (.7).
# Producers (mem-promote, memory-consolidation-run, memory-staleness) append
# review items to .review-queue.json (beside .consolidation-state.json under the
# memory state tier). The SessionStart banner (memory-review-banner.sh) and the
# UserPromptSubmit re-firing mandate (prompt-context.sh) READ the queue; the
# Stop-block (stop-checkpoint-check.sh) reads it for high-severity CONFLICTS.
# Failure mode: BLOCK-AND-LOG. enqueue_item validates the appended item against
# schemas/review-queue-schema.json (when a validator is present); on an invalid
# item it REFUSES the write and logs to the queue's sidecar log — never
# write-and-hope (operator Skill Creation Rules +.7).
# Bash 3.2 clean (R-23): no associative arrays, no mapfile, no ${var,,}.

# Resolve the memory state tier + queue paths. paths.sh emits the
# resolution helpers; source it if not already loaded.
if ! command -v resolve_memory_dir >/dev/null 2>&1; then
  _rq_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  [ -r "$_rq_self_dir/paths.sh" ] && source "$_rq_self_dir/paths.sh"
  unset _rq_self_dir
fi

_rq_memory_dir() {
  if command -v resolve_memory_dir >/dev/null 2>&1; then
    resolve_memory_dir
  else
    echo "${CLAUDE_HOME:-$HOME/.claude}/projects/_global/memory"
  fi
}

_rq_queue_file() {
  echo "$(_rq_memory_dir)/.review-queue.json"
}

_rq_log_file() {
  echo "$(_rq_memory_dir)/.review-queue-log.md"
}

_rq_schema_path() {
  # Repo-only schema; resolved relative to the install root for validation.
  echo "${REVIEW_QUEUE_SCHEMA:-${CLAUDE_HOME:-$HOME/.claude}/schemas/review-queue-schema.json}"
}

# --- threshold resolution: env var > user-manifest > default ----
# high_severity_pending_days / defer_count_cap are resolved HERE so they are
# genuinely manifest-driven. Pre-the functions read MEMORY_REVIEW_* env vars
# that NOTHING set, so the schema-declared knobs were dead. Env override wins
# (tests/CI); else the user-manifest value via paths.sh _manifest_get; else the
_rq_high_sev_days() {
  local v="${MEMORY_REVIEW_HIGH_SEV_DAYS:-}"
  if [ -z "$v" ] && command -v _manifest_get >/dev/null 2>&1; then
    v="$(_manifest_get .hooks.memory_review.high_severity_pending_days 2>/dev/null)"
  fi
  case "$v" in ''|*[!0-9]*) v=3 ;; esac
  printf '%s' "$v"
}
_rq_defer_cap() {
  local v="${MEMORY_REVIEW_DEFER_CAP:-}"
  if [ -z "$v" ] && command -v _manifest_get >/dev/null 2>&1; then
    v="$(_manifest_get .hooks.memory_review.defer_count_cap 2>/dev/null)"
  fi
  case "$v" in ''|*[!0-9]*) v=2 ;; esac
  printf '%s' "$v"
}

_rq_log() {
  # $1 = message
  local logf
  logf="$(_rq_log_file)"
  mkdir -p "$(dirname "$logf")" 2>/dev/null || true
  printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$logf" 2>/dev/null || true
}

_rq_ensure_queue() {
  local qf
  qf="$(_rq_queue_file)"
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  if [ ! -f "$qf" ]; then
    printf '%s\n' '{"version":1,"items":[]}' > "$qf"
  fi
  echo "$qf"
}

# enqueue_item <item-json>
# Validates the item against the queue item shape (severity / state /
# defer_count / dismiss_count / class) and appends it to .review-queue.json.
# Returns 0 on a successful append, non-zero (and a log line) on a refused
# invalid item (block-and-log). De-dupes by item id (idempotent).
enqueue_item() {
  local item_json="$1"
  if [ -z "$item_json" ]; then
    _rq_log "REFUSED enqueue: empty item payload"
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _rq_log "REFUSED enqueue: jq unavailable (cannot validate/append)"
    return 3
  fi
  # Well-formedness + required-field gate (the inline block-and-log validation —
  # severity, state, class, defer_count, dismiss_count are the queue-item
  # contract per.7 + review-queue-schema.json).
  if ! printf '%s' "$item_json" | jq -e \
      '(.id|type=="string") and (.severity|type=="string") and (.state|type=="string") and (.class|type=="string") and (.defer_count|type=="number") and (.dismiss_count|type=="number")' \
      >/dev/null 2>&1; then
    _rq_log "REFUSED enqueue: item failed required-field validation: $(printf '%s' "$item_json" | head -c 200)"
    return 4
  fi
  # Optional schema-conformance gate when a validator + schema are present.
  local schema
  schema="$(_rq_schema_path)"
  if [ -r "$schema" ] && command -v python3 >/dev/null 2>&1; then
    local serr
    serr=$(printf '%s' "$item_json" | python3 -c '
import sys, json
try:
    import jsonschema
except Exception:
    sys.exit(0)
try:
    schema=json.load(open(sys.argv[1]))
    item=json.load(sys.stdin)
except Exception:
    sys.exit(0)
errs=list(jsonschema.Draft7Validator(schema).iter_errors(item))
if errs:
    print(errs[0].message)
' "$schema" 2>/dev/null)
    if [ -n "$serr" ]; then
      _rq_log "REFUSED enqueue: schema violation: $serr"
      return 5
    fi
  fi

  local qf id
  qf="$(_rq_ensure_queue)"
  id=$(printf '%s' "$item_json" | jq -r '.id')
  # Idempotent: replace an existing item with the same id, else append.
  if jq -e --arg id "$id" '.items[]? | select(.id==$id)' "$qf" >/dev/null 2>&1; then
    jq --arg id "$id" --argjson it "$item_json" \
      '.items = ([.items[] | if .id==$id then $it else . end])' \
      "$qf" > "$qf.tmp" && mv "$qf.tmp" "$qf"
  else
    jq --argjson it "$item_json" '.items += [$it]' "$qf" > "$qf.tmp" && mv "$qf.tmp" "$qf"
  fi
  _rq_log "enqueued id=$id severity=$(printf '%s' "$item_json" | jq -r '.severity') class=$(printf '%s' "$item_json" | jq -r '.class')"
  return 0
}

# --- queue-drain state-transition primitives (lib side,) --------
# The converse of enqueue_item: without these, queued items can never leave the
# OPEN set (the.7 surfacing mechanism is non-terminating). Each
# is a jq read-modify-write of the matching .id ($qf.tmp -> mv, mirroring
# enqueue_item), idempotent, block-and-log, bash-3.2-clean. The `review`
# SKILL.md rubric DRIVES these; the primitives are independently testable.
# CLEAR-CONDITION: an item leaves the OPEN set ONLY via confirm_item
# OR reject_item. defer_item keeps it in the queue (defer_count++); a bare defer
# (no reason) is block-and-log refused, and a 2nd defer force-escalates (state
# stays escalated-in-queue, never silently cleared). suppress_item is the
# 3-strike low-severity hygiene path (the 3-strike + revalidation-exempt POLICY
# is applied by the caller; suppress_item itself does the state write).

# _rq_item_present <id> — true (exit 0) when an item with .id==<id> exists.
_rq_item_present() {
  local qf="$1" id="$2"
  jq -e --arg id "$id" '.items[]? | select(.id==$id)' "$qf" >/dev/null 2>&1
}

# confirm_item <id> — transition .state to "confirmed" (leaves the OPEN set).
confirm_item() {
  local id="$1" qf
  if [ -z "$id" ]; then _rq_log "REFUSED confirm: missing id"; return 2; fi
  command -v jq >/dev/null 2>&1 || { _rq_log "REFUSED confirm id=$id: jq unavailable"; return 3; }
  qf="$(_rq_ensure_queue)"
  if ! _rq_item_present "$qf" "$id"; then
    _rq_log "REFUSED confirm: no item with id=$id"; return 4
  fi
  jq --arg id "$id" \
    '.items = ([.items[] | if .id==$id then (.state="confirmed") else . end])' \
    "$qf" > "$qf.tmp" && mv "$qf.tmp" "$qf" || { _rq_log "REFUSED confirm id=$id: write failed"; return 5; }
  _rq_log "confirmed id=$id"
  return 0
}

# reject_item <id> <reason> — transition .state to "rejected" + record
# reject_reason. Reason is MANDATORY (block-and-log on missing). Leaves OPEN.
reject_item() {
  local id="$1" reason="$2" qf
  if [ -z "$id" ]; then _rq_log "REFUSED reject: missing id"; return 2; fi
  if [ -z "$reason" ]; then _rq_log "REFUSED reject id=$id: reason MANDATORY"; return 6; fi
  command -v jq >/dev/null 2>&1 || { _rq_log "REFUSED reject id=$id: jq unavailable"; return 3; }
  qf="$(_rq_ensure_queue)"
  if ! _rq_item_present "$qf" "$id"; then
    _rq_log "REFUSED reject: no item with id=$id"; return 4
  fi
  jq --arg id "$id" --arg reason "$reason" \
    '.items = ([.items[] | if .id==$id then (.state="rejected" | .reject_reason=$reason) else . end])' \
    "$qf" > "$qf.tmp" && mv "$qf.tmp" "$qf" || { _rq_log "REFUSED reject id=$id: write failed"; return 5; }
  _rq_log "rejected id=$id reason=$reason"
  return 0
}

# defer_item <id> <reason> — transition .state to "deferred", record
# defer_reason, increment defer_count. Reason is MANDATORY. KEEPS the item in the
# queue. defer_count >= the defer-cap (default 2) force-escalates the item (state
# stays in the queue; never silently cleared) — the defer-cap.
defer_item() {
  local id="$1" reason="$2" qf defer_cap
  if [ -z "$id" ]; then _rq_log "REFUSED defer: missing id"; return 2; fi
  if [ -z "$reason" ]; then _rq_log "REFUSED defer id=$id: reason MANDATORY"; return 6; fi
  command -v jq >/dev/null 2>&1 || { _rq_log "REFUSED defer id=$id: jq unavailable"; return 3; }
  defer_cap="$(_rq_defer_cap)"
  qf="$(_rq_ensure_queue)"
  if ! _rq_item_present "$qf" "$id"; then
    _rq_log "REFUSED defer: no item with id=$id"; return 4
  fi
  jq --arg id "$id" --arg reason "$reason" --argjson cap "$defer_cap" \
    '.items = ([.items[] | if .id==$id then
        (.defer_count = ((.defer_count // 0) + 1) | .defer_reason=$reason
         | .state = "deferred"
         | .escalated = (.defer_count >= $cap))
       else . end])' \
    "$qf" > "$qf.tmp" && mv "$qf.tmp" "$qf" || { _rq_log "REFUSED defer id=$id: write failed"; return 5; }
  local dc esc
  dc=$(jq -r --arg id "$id" '.items[]? | select(.id==$id) | .defer_count' "$qf" 2>/dev/null)
  esc=$(jq -r --arg id "$id" '.items[]? | select(.id==$id) | .escalated' "$qf" 2>/dev/null)
  _rq_log "deferred id=$id reason=$reason defer_count=$dc escalated=$esc"
  return 0
}

# suppress_item <id> — transition .state to "suppressed" (3-strike low-severity
# hygiene path; the 3-strike + revalidation-exempt POLICY is the caller's,
# this primitive does the state write only). Leaves the OPEN set.
suppress_item() {
  local id="$1" qf
  if [ -z "$id" ]; then _rq_log "REFUSED suppress: missing id"; return 2; fi
  command -v jq >/dev/null 2>&1 || { _rq_log "REFUSED suppress id=$id: jq unavailable"; return 3; }
  qf="$(_rq_ensure_queue)"
  if ! _rq_item_present "$qf" "$id"; then
    _rq_log "REFUSED suppress: no item with id=$id"; return 4
  fi
  jq --arg id "$id" \
    '.items = ([.items[] | if .id==$id then (.state="suppressed") else . end])' \
    "$qf" > "$qf.tmp" && mv "$qf.tmp" "$qf" || { _rq_log "REFUSED suppress id=$id: write failed"; return 5; }
  _rq_log "suppressed id=$id"
  return 0
}

# review_queue_pending_count — count unaddressed items (state == open).
review_queue_pending_count() {
  local qf
  qf="$(_rq_queue_file)"
  [ -f "$qf" ] || { echo 0; return 0; }
  command -v jq >/dev/null 2>&1 || { echo 0; return 0; }
  jq -r '[.items[]? | select(.state=="open")] | length' "$qf" 2>/dev/null || echo 0
}

# review_queue_revalidation_count — count open low-severity revalidation items
# (the aggregated banner line; STALE ≥180d). Suppress-exempt.
review_queue_revalidation_count() {
  local qf
  qf="$(_rq_queue_file)"
  [ -f "$qf" ] || { echo 0; return 0; }
  command -v jq >/dev/null 2>&1 || { echo 0; return 0; }
  jq -r '[.items[]? | select(.state=="open" and .class=="revalidation")] | length' "$qf" 2>/dev/null || echo 0
}

# review_queue_has_high_severity_conflict — true (exit 0) when an open
# high-severity CONFLICT item exists. The ONLY class that may reach the
# Stop-block (which itself yields to R-26).
review_queue_has_high_severity_conflict() {
  local qf n
  qf="$(_rq_queue_file)"
  [ -f "$qf" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  n=$(jq -r '[.items[]? | select(.state=="open" and .severity=="high" and .class=="conflict")] | length' "$qf" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ]
}

# review_queue_has_aged_or_deferred — true when an open high-severity item has
# been pending > N days OR carries defer_count >= defer_cap (the re-firing mandate
# trigger). Thresholds resolved env > user-manifest.json :: hooks.memory_review >
# default (: _rq_high_sev_days / _rq_defer_cap).
review_queue_has_aged_or_deferred() {
  local qf days_cap defer_cap n
  qf="$(_rq_queue_file)"
  [ -f "$qf" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  days_cap="$(_rq_high_sev_days)"
  defer_cap="$(_rq_defer_cap)"
  local now_epoch
  now_epoch=$(date +%s)
  n=$(jq -r --argjson now "$now_epoch" --argjson days "$days_cap" --argjson dcap "$defer_cap" '
    [.items[]?
      | select(.state=="open")
      | select(
          (.defer_count >= $dcap)
          or ( (.severity=="high")
               and (((.enqueued_at // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0) as $e
                    | (($now - $e) / 86400) >= $days) )
        )
    ] | length' "$qf" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ]
}

# memory_review_opt_out — true (exit 0) when the operator has opted out of the
# memory-review surfacing via user-manifest.json :: hooks.memory_review.enabled
# == false. Default = enabled (opt-out, not opt-in).
memory_review_opt_out() {
  local enabled
  if command -v _manifest_get >/dev/null 2>&1; then
    enabled="$(_manifest_get .hooks.memory_review.enabled 2>/dev/null || true)"
  fi
  [ "$enabled" = "false" ]
}
