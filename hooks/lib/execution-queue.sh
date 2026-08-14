#!/bin/bash
# hooks/lib/execution-queue.sh — execution-queue persistence for the
# orchestrator dispatch engine. Source this file — do not execute it.
#
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/execution-queue.sh"
#
# (NET-NEW). The connector dispatch.sh hard-sources at
# load time (dispatch.sh's QUEUE_LIB=$HOOKS_DIR/lib/execution-queue.sh export +
# source). Provides queue persistence for the --overnight / --delay ≥4h timing
# modes and the queue ops (--hold/--unhold/--queue-status). The ported engine
# cannot run until this lib exists (HARD intra-SP dep →/).
#
# Function contract consumed by dispatch.sh:
#   exec_queue_add <name> <type> <ref> <model> <timeout> <budget> <priority> <queued_by>
#   exec_queue_hold <name>
#   exec_queue_unhold <name>
#   exec_queue_list [status]
# Plus the executor-side ops (pick/update/remove/prune) the overnight cron
# wrapper consumes.
#
# Hook-portability: the queue file + lock resolve under
# $CLAUDE_STATE_ROOT via hooks/lib/paths.sh — NO $HOME/.claude literal. The
# queue is machine-local ephemeral state (same tier as the coordination
# registry per).
#
# Bash 3.2 clean (R-23): no associative arrays, no mapfile/readarray, no
# parameter-expansion case conversion, no GNU-only constructs.

# Resolve state-root via paths.sh (no $HOME/.claude literal — Hook-portability
# AC). HOOKS_STATE resolves under $CLAUDE_STATE_ROOT per .
source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"

EXEC_QUEUE_FILE="${EXEC_QUEUE_FILE:-$HOOKS_STATE/execution-queue.json}"
EXEC_QUEUE_LOCK="${EXEC_QUEUE_LOCK:-$HOOKS_STATE/execution-queue.lock}"
MAX_EXEC_QUEUE_DEPTH="${MAX_EXEC_QUEUE_DEPTH:-50}"
EXEC_PRUNE_AGE_DAYS="${EXEC_PRUNE_AGE_DAYS:-7}"

# Ensure queue file exists with valid structure.
exec_ensure_queue() {
  mkdir -p "$(dirname "$EXEC_QUEUE_FILE")" 2>/dev/null || true
  if [ ! -f "$EXEC_QUEUE_FILE" ] || [ ! -s "$EXEC_QUEUE_FILE" ]; then
    printf '{"queue":[]}\n' > "$EXEC_QUEUE_FILE"
  fi
}

# Read queue JSON. Creates file if missing.
exec_read_queue() {
  exec_ensure_queue
  cat "$EXEC_QUEUE_FILE"
}

# Atomic write. Arg: JSON content.
exec_write_queue() {
  local tmp="${EXEC_QUEUE_FILE}.tmp.$$"
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$EXEC_QUEUE_FILE"
}

# Add item to queue.
# Args: name, type (job|plan), ref (path to job .md or manifest), model,
#       timeout, budget, priority (normal|urgent), queued_by
# Returns 0 on success, 1 if queue full or duplicate.
exec_queue_add() {
  local name="$1" type="$2" ref="$3" model="${4:-sonnet}" timeout="${5:-3600}" budget="${6:-}" priority="${7:-normal}" queued_by="${8:-manual}"
  local queue now depth existing

  queue=$(exec_read_queue)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Check for duplicate (same name, status queued or running)
  existing=$(echo "$queue" | jq -r --arg n "$name" \
    '[.queue[] | select(.name == $n and (.status == "queued" or .status == "running"))] | length')
  if [ "${existing:-0}" -gt 0 ]; then
    return 1
  fi

  # Check max depth (only count active items)
  depth=$(echo "$queue" | jq '[.queue[] | select(.status == "queued" or .status == "running" or .status == "held")] | length')
  if [ "${depth:-0}" -ge "$MAX_EXEC_QUEUE_DEPTH" ]; then
    return 1
  fi

  queue=$(echo "$queue" | jq \
    --arg n "$name" --arg t "$type" --arg r "$ref" --arg m "$model" \
    --argjson to "$timeout" --arg b "$budget" --arg pri "$priority" \
    --arg qb "$queued_by" --arg ts "$now" \
    '.queue += [{
      "name": $n,
      "type": $t,
      "ref": $r,
      "model": $m,
      "timeout": $to,
      "budget": (if $b == "" then null else ($b | tonumber) end),
      "status": "queued",
      "priority": $pri,
      "queued_at": $ts,
      "queued_by": $qb,
      "started_at": null,
      "completed_at": null,
      "result": null
    }]')

  exec_write_queue "$queue"
  return 0
}

# Pick up to N queued items (urgent first, then FIFO). Skips held items.
# Args: max_count. Outputs JSON array.
exec_queue_pick() {
  local max="${1:-3}"
  exec_read_queue | jq --argjson max "$max" \
    '[.queue[] | select(.status == "queued")] |
     sort_by(if .priority == "urgent" then 0 else 1 end, .queued_at) |
     .[:$max]'
}

# Update item status. Args: name, new_status, result (optional).
exec_queue_update() {
  local name="$1" new_status="$2" result="${3:-}"
  local queue now

  queue=$(exec_read_queue)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [ "$new_status" = "running" ]; then
    queue=$(echo "$queue" | jq --arg n "$name" --arg s "$new_status" --arg ts "$now" \
      '(.queue[] | select(.name == $n and (.status == "queued"))) |= (.status = $s | .started_at = $ts)')
  elif [ "$new_status" = "complete" ] || [ "$new_status" = "failed" ]; then
    if [ -n "$result" ]; then
      queue=$(echo "$queue" | jq --arg n "$name" --arg s "$new_status" --arg ts "$now" --arg r "$result" \
        '(.queue[] | select(.name == $n and (.status == "running"))) |= (.status = $s | .completed_at = $ts | .result = $r)')
    else
      queue=$(echo "$queue" | jq --arg n "$name" --arg s "$new_status" --arg ts "$now" \
        '(.queue[] | select(.name == $n and (.status == "running"))) |= (.status = $s | .completed_at = $ts)')
    fi
  else
    queue=$(echo "$queue" | jq --arg n "$name" --arg s "$new_status" \
      '(.queue[] | select(.name == $n and (.status == "queued" or .status == "running" or .status == "held"))) |= (.status = $s)')
  fi

  exec_write_queue "$queue"
}

# Hold an item — executor skips it, item keeps its place.
# Args: name
exec_queue_hold() {
  local name="$1"
  local queue
  queue=$(exec_read_queue)
  queue=$(echo "$queue" | jq --arg n "$name" \
    '(.queue[] | select(.name == $n and .status == "queued")) |= (.status = "held")')
  exec_write_queue "$queue"
}

# Unhold an item — set back to queued.
# Args: name
exec_queue_unhold() {
  local name="$1"
  local queue
  queue=$(exec_read_queue)
  queue=$(echo "$queue" | jq --arg n "$name" \
    '(.queue[] | select(.name == $n and .status == "held")) |= (.status = "queued")')
  exec_write_queue "$queue"
}

# Remove item entirely.
# Args: name
exec_queue_remove() {
  local name="$1"
  local queue
  queue=$(exec_read_queue)
  queue=$(echo "$queue" | jq --arg n "$name" \
    '.queue |= [.[] | select(.name != $n)]')
  exec_write_queue "$queue"
}

# Prune completed/failed items older than EXEC_PRUNE_AGE_DAYS.
exec_queue_prune() {
  local queue cutoff_epoch now_epoch
  queue=$(exec_read_queue)
  now_epoch=$(date +%s)
  cutoff_epoch=$(( now_epoch - EXEC_PRUNE_AGE_DAYS * 86400 ))

  queue=$(echo "$queue" | jq --argjson cutoff "$cutoff_epoch" '
    .queue |= [.[] | select(
      (.status == "queued" or .status == "running" or .status == "held") or
      ((.queued_at | split(".")[0] | sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime) > $cutoff)
    )]')

  exec_write_queue "$queue"
}

# List all items with optional status filter. Args: status (optional).
# Outputs JSON array.
exec_queue_list() {
  local status="${1:-}"
  if [ -n "$status" ]; then
    exec_read_queue | jq --arg s "$status" '[.queue[] | select(.status == $s)]'
  else
    exec_read_queue | jq '.queue'
  fi
}
