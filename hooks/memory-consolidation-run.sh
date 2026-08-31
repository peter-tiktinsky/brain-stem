#!/bin/bash
# Background consolidation runner — performs mechanical auto-fix operations.
# Spawned by memory-consolidation-check.sh. Runs detached.
# Only does auto-fix checks: staleness (read-only flag), orphans, dead refs,
# temporal hygiene, index-dedup, budget. Manual checks (overlap, status
# verification, conflicts, supersession adjudication) stay in /librarian.
#
# two code defects fixed atomically with the schema 2.0.0 bump —
#   (1) orphan section-map now reads the schema ENUM retrieval-type sections
#       (## Semantic / ## Procedural / ## Episodic), mapping the `type:`
#       frontmatter value to its section, instead of the old top-level
#       provenance sections (## User/## Feedback/...) that match nothing
#       post-reorg (.6).
#   (2) cap-count computes raw wc -l AND byte count AND char-line count, with a
#       comment-stripped raw count, and gates on the LARGER (
#       .5/.6/) instead of raw wc -l only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Errexit-safe pre-test source form (the memory-consolidation-check.sh:37-38 idiom): a bare
# `source` under `set -e` hard-aborts the SessionEnd chain when lib/ is absent, and the
# shorter `source X || exit 0` is INERT under errexit (the || clause is unreachable). Failure
# mode is silent no-op, never hard-abort.
{ [ -r "$SCRIPT_DIR/lib/paths.sh" ] && source "$SCRIPT_DIR/lib/paths.sh"; } || exit 0
{ [ -r "$SCRIPT_DIR/lib/lockf.sh" ] && source "$SCRIPT_DIR/lib/lockf.sh"; } || exit 0
# (T-09): the revalidation-enqueue producer feeds the review-queue
# drain (primitives confirm_item/reject_item/defer_item/suppress_item).
# Source review-queue.sh for enqueue_item; degrade gracefully if absent.
[ -r "$SCRIPT_DIR/lib/review-queue.sh" ] && source "$SCRIPT_DIR/lib/review-queue.sh"
MEMORY_DIR="$(resolve_memory_dir)"
STATE_FILE="$MEMORY_DIR/.consolidation-state.json"
LOCK_FILE="$MEMORY_DIR/.consolidation.lock"
LOG_FILE="${CLAUDE_LOG_DIR:-$MEMORY_DIR}/.consolidation-log.md"  # G6: LOG → state/logs/; state+lock STAY in MEMORY_DIR
INDEX_FILE="$MEMORY_DIR/MEMORY.md"

# single-instance guard via lockf (.6) — replaces the
# hand-rolled PID-lock TOCTOU window. The outer call re-execs this script under
# /usr/bin/lockf -k -t 0; on contention (another consolidation running) it skips
# cleanly. The kernel releases the advisory lock on process death — no stale
# lock to reap. The inner (re-execed) invocation returns and proceeds below.
mkdir -p "$MEMORY_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
claude_lockf_reexec "$LOCK_FILE" "$@"

# Single 180-day re-validation interval. Honored if exported by the
# spawning check.sh; falls back to the canonical default otherwise.
STALE_DAYS="${STALE_DAYS:-180}"
EXPIRED_DAYS="${EXPIRED_DAYS:-360}"

# R-59 load-guard thresholds (.5; the byte cap is the governing
# trigger). (T-08): read from the SHIPPED foundation-master.json
# bundle slot (.mandatory_files.mandates._memory_md_cap.thresholds.*), NOT the
# repo-only pillar mandatory-files-rules.json — the bundle is what adopters get
# (the repo-only pillar is absent on an adopter, so the old read fell back to
# the baked-in defaults). Routes through hooks/lib/foundation-overlay-load.sh,
# WITH --force-override: this is a hook-side READ, not an overlay write, and
# reads pass the flag per the loader's call-site contract. RE-ADJUDICATED at
# the array-identity build (the walk's wider entity domain raises R-52 deny
# frequency, and every deny was killing the adopter's declared cap override —
# the exact mechanism this bundle read exists for, degraded for days under one
# unrelated live collision): R-52 policy state no longer degrades this read;
# R-52 DETECTION is owned by the purpose-built probes (pre-write-guard's
# write-time probe, the install-lane apply-time probe), never by this runner.
# The FAIL-OPEN posture stands for structural failures — missing loader/bundle,
# jq absent, parse error — because the consolidation layer must keep running:
# it degrades to the documented defaults and SAYS SO. (That availability
# posture is this runner's own recorded design; — previously cited
# here — governs registry.sh's hook-EMISSION validator, a different surface.)
# The three fallback constants below are a DUPLICATE of the foundation's
# declared _memory_md_cap.thresholds, held in lockstep by a maintainer-tree
# parity fixture that reads both sides at test time and goes RED when either
# changes alone — they are NOT an independent default. The duplication is
# irreducible: the fallback exists precisely for when the bundle is
# unreachable, so it cannot be derived from the bundle. A degraded run is
# reported visibly (log + stderr) below rather than silently applying stale
# caps.
CAP_LINES=200
CAP_BYTES=25600
CAP_CHAR_LINE=200
CAP_SOURCE="fallback"
CAP_DEGRADE_CAUSE="loader unavailable (hooks/lib/foundation-overlay-load.sh missing or jq absent)"
_OVERLAY_LOAD="$SCRIPT_DIR/lib/foundation-overlay-load.sh"
_CAP_QUERY='.mandatory_files.mandates._memory_md_cap.thresholds'
if [[ -r "$_OVERLAY_LOAD" ]] && command -v jq >/dev/null 2>&1; then
  _cap_json=$(bash "$_OVERLAY_LOAD" --force-override --query "$_CAP_QUERY" 2>/dev/null || true)
  if [[ -n "$_cap_json" ]] && printf '%s' "$_cap_json" | jq empty >/dev/null 2>&1; then
    _l=$(printf '%s' "$_cap_json" | jq -r '.max_lines // empty' 2>/dev/null || true)
    _b=$(printf '%s' "$_cap_json" | jq -r '.max_bytes // empty' 2>/dev/null || true)
    _c=$(printf '%s' "$_cap_json" | jq -r '.max_chars_per_line // empty' 2>/dev/null || true)
    [[ -n "$_l" ]] && CAP_LINES="$_l"
    [[ -n "$_b" ]] && CAP_BYTES="$_b"
    [[ -n "$_c" ]] && CAP_CHAR_LINE="$_c"
    if [[ -n "$_l" || -n "$_b" || -n "$_c" ]]; then
      CAP_SOURCE="bundle"
    else
      CAP_DEGRADE_CAUSE="loader query succeeded but the bundle slot ${_CAP_QUERY} is missing or empty"
    fi
  else
    CAP_DEGRADE_CAUSE="loader query failed or returned empty (unreadable bundle or parse error; R-52 state cannot cause this — the read passes --force-override)"
  fi
fi
if [[ "$CAP_SOURCE" != "bundle" ]]; then
  printf 'memory-consolidation-run.sh: cap-config DEGRADED — fallback caps %sL/%sB/%sC in effect; %s\n' \
    "$CAP_LINES" "$CAP_BYTES" "$CAP_CHAR_LINE" "$CAP_DEGRADE_CAUSE" >&2
fi

# toggle: short-circuit when user opted out via /onboard.
# Default-enabled; opt-out is explicit `false`. Audit log entry written to
# $LOG_FILE before exit so absence-of-runs is observable.
hook_enabled="$(_manifest_get .behavioral.hook_preferences.memory_consolidation_enabled 2>/dev/null || true)"
if [ "$hook_enabled" = "false" ]; then
  mkdir -p "$MEMORY_DIR"
  printf '\n## Skipped — %s\n- Reason: user-manifest hook_preferences.memory_consolidation_enabled=false\n' \
    "$(date +"%Y-%m-%d %H:%M")" >> "$LOG_FILE" 2>/dev/null || true
  exit 0
fi

START_TIME=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date +%Y-%m-%d)

FILES_SCANNED=0
STALE_FLAGGED=0
EXPIRED_FLAGGED=0
ORPHANS_ADDED=0
DEAD_REFS_REMOVED=0
TEMPORAL_FIXES=0
BUDGET_STATUS="GREEN"
ERRORS=""

# No hand-rolled lock cleanup: lockf owns the lock lifecycle (kernel-released
# on process death). The LOCK_FILE is kept (-k) and reused across invocations.

# Map a `type:` frontmatter value (the schema enum) to its MEMORY.md section
# header. This replaces the old provenance-prefix map (## User/## Feedback/...)
# that matched nothing after the type-grouped reorg (defect 1).
type_to_section() {
  case "$1" in
    semantic)   echo "## Semantic" ;;
    procedural) echo "## Procedural" ;;
    episodic)   echo "## Episodic" ;;
    *)          echo "" ;;
  esac
}

# (T-09): revalidation-enqueue producer. For each STALE (≥180d) or
# EXPIRED (≥360d) non-episodic memory file, enqueue a review-queue item of
# class='revalidation' so review_queue_revalidation_count > 0 and the single
# aggregated banner line ("N memories due for revalidation") surfaces. STALE =
# low-severity (suppress-EXEMPT per.7); EXPIRED escalates to
# medium-severity itemized {revalidate|supersede|archive}. The id is a stable
# dedupe key (memory-basename) so a re-scan does NOT double-enqueue (enqueue_item
# is idempotent on id — block-and-log). No-op when review-queue.sh is absent
# (graceful-degrade) or jq is missing.
# $1 file-path  $2 last_validated  $3 age_days  $4 tier (stale|expired)
enqueue_revalidation() {
  command -v enqueue_item >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local f="$1" lv="$2" age="$3" tier="$4"
  local base sev id summary
  base=$(basename "$f")
  id="revalidation-${base}"
  if [ "$tier" = "expired" ]; then
    sev="medium"
    summary="${base} last_validated=${lv} is ${age}d old (EXPIRED ≥360d) — revalidate | supersede | archive"
  else
    sev="low"
    summary="${base} last_validated=${lv} is ${age}d old (STALE ≥180d) — due for revalidation"
  fi
  local item
  item=$(jq -nc \
    --arg id "$id" \
    --arg severity "$sev" \
    --arg class "revalidation" \
    --arg summary "$summary" \
    --arg memory_ref "$base" \
    --arg enqueued_at "$NOW_ISO" \
    '{
      id: $id,
      severity: $severity,
      state: "open",
      class: $class,
      defer_count: 0,
      dismiss_count: 0,
      summary: $summary,
      memory_ref: $memory_ref,
      enqueued_at: $enqueued_at
    }') || return 0
  enqueue_item "$item" >/dev/null 2>&1 || true
  return 0
}

# --- Check 1: Staleness scan (read-only flag; propose-only states) ---
# decay model (.4): last_validated is the SOLE decay input
# (required per schema 2.0.0). A SINGLE 180-day interval applies to all
# non-episodic memory; episodic NEVER decays. States:
#   FRESH (<180d) → no action
#   STALE (180-360d) → propose revalidate (flagged)
#   EXPIRED (≥360d) → propose {revalidate|supersede|archive} (flagged)
# ALL propose-only — this scan NEVER deletes/archives; it only counts flags for
# the audit log. The actual revalidation surfacing is the review-queue/banner
#. `updated` does NOT reset the clock.
for f in "$MEMORY_DIR"/*.md; do
  [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
  [[ ! -f "$f" ]] && continue
  FILES_SCANNED=$((FILES_SCANNED + 1))

  TYPE=$(awk '/^---$/{n++; next} n==1 && /^type:/{sub(/^type: */, ""); print; exit}' "$f")
  # Episodic never decays — skip the staleness flag entirely.
  [[ "$TYPE" == "episodic" ]] && continue

  LAST_VALIDATED=$(awk '/^---$/{n++; next} n==1 && /^last_validated:/{sub(/^last_validated: */, ""); print; exit}' "$f")
  if [[ -z "$LAST_VALIDATED" ]]; then
    LAST_VALIDATED=$(awk '/^---$/{n++; next} n==1 && /^last_verified:/{sub(/^last_verified: */, ""); print; exit}' "$f")
  fi

  if [[ -z "$LAST_VALIDATED" ]]; then
    # No decay input at all → propose revalidate (treat as STALE).
    STALE_FLAGGED=$((STALE_FLAGGED + 1))
    continue
  fi

  LV_EPOCH=$(date -jf "%Y-%m-%d" "$LAST_VALIDATED" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE_DAYS=$(( (NOW_EPOCH - LV_EPOCH) / 86400 ))

  if [[ "$AGE_DAYS" -ge "$EXPIRED_DAYS" ]]; then
    EXPIRED_FLAGGED=$((EXPIRED_FLAGGED + 1))
    enqueue_revalidation "$f" "$LAST_VALIDATED" "$AGE_DAYS" "expired"
  elif [[ "$AGE_DAYS" -ge "$STALE_DAYS" ]]; then
    STALE_FLAGGED=$((STALE_FLAGGED + 1))
    enqueue_revalidation "$f" "$LAST_VALIDATED" "$AGE_DAYS" "stale"
  fi
done

# --- Check 4: Orphan check (additive) ---
# Memory files not referenced in MEMORY.md get an index entry under their
# retrieval-type section, read from the `type:` frontmatter (schema enum).
if [[ -f "$INDEX_FILE" ]]; then
  for f in "$MEMORY_DIR"/*.md; do
    BASE=$(basename "$f")
    [[ "$BASE" == "MEMORY.md" ]] && continue
    [[ ! -f "$f" ]] && continue

    if ! grep -q "$BASE" "$INDEX_FILE" 2>/dev/null; then
      NAME=$(awk '/^---$/{n++; next} n==1 && /^name:/{sub(/^name: */, ""); print; exit}' "$f")
      DESC=$(awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description: */, ""); print; exit}' "$f")
      TYPE=$(awk '/^---$/{n++; next} n==1 && /^type:/{sub(/^type: */, ""); print; exit}' "$f")

      if [[ -n "$NAME" ]]; then
        SECTION_HEADER="$(type_to_section "$TYPE")"
        if [[ -n "$SECTION_HEADER" ]] && grep -q "^$SECTION_HEADER" "$INDEX_FILE"; then
          ENTRY="- [${BASE}](memory/${BASE}) — ${DESC}"
          awk -v hdr="$SECTION_HEADER" -v entry="$ENTRY" '
            $0 == hdr { in_section=1; print; next }
            in_section && /^$/ { print entry; in_section=0 }
            in_section && /^## / { print entry; print ""; in_section=0 }
            { print }
            END { if (in_section) print entry }
          ' "$INDEX_FILE" > "${INDEX_FILE}.tmp" && mv "${INDEX_FILE}.tmp" "$INDEX_FILE"
          ORPHANS_ADDED=$((ORPHANS_ADDED + 1))
        fi
      fi
    fi
  done
fi

# --- Check 5: Index accuracy (dead-ref removal) ---
if [[ -f "$INDEX_FILE" ]]; then
  TEMP_INDEX="${INDEX_FILE}.tmp.$$"
  REMOVED=false
  while IFS= read -r line; do
    if [[ "$line" =~ ^\-\ \[([^\]]+)\] ]]; then
      REF_FILE="${BASH_REMATCH[1]}"
      if [[ ! -f "$MEMORY_DIR/$REF_FILE" ]]; then
        DEAD_REFS_REMOVED=$((DEAD_REFS_REMOVED + 1))
        REMOVED=true
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$TEMP_INDEX"
  done < "$INDEX_FILE"

  if [[ "$REMOVED" == "true" ]]; then
    mv "$TEMP_INDEX" "$INDEX_FILE"
  else
    rm -f "$TEMP_INDEX"
  fi
fi

# --- Check 7: Temporal hygiene ---
# Only fix the unambiguous yesterday/today/tomorrow patterns outside
# frontmatter and quotes.
RELATIVE_PATTERNS='(^|[^"'"'"'])\b(yesterday|today|tomorrow|last week|this week|next week|last month|this month|next month)\b([^"'"'"']|$)'

for f in "$MEMORY_DIR"/*.md; do
  [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
  [[ ! -f "$f" ]] && continue

  BODY=$(awk '/^---$/{n++; next} n>=2{print}' "$f")
  if echo "$BODY" | grep -iEq "$RELATIVE_PATTERNS"; then
    ANCHOR=$(awk '/^---$/{n++; next} n==1 && /^last_validated:/{sub(/^last_validated: */, ""); print; exit}' "$f")
    [[ -z "$ANCHOR" ]] && ANCHOR=$(awk '/^---$/{n++; next} n==1 && /^last_verified:/{sub(/^last_verified: */, ""); print; exit}' "$f")
    if [[ -z "$ANCHOR" ]]; then
      ANCHOR=$(stat -f "%Sm" -t "%Y-%m-%d" "$f" 2>/dev/null || echo "$TODAY")
    fi

    ANCHOR_EPOCH=$(date -jf "%Y-%m-%d" "$ANCHOR" +%s 2>/dev/null || continue)
    YESTERDAY=$(date -jf "%s" "$((ANCHOR_EPOCH - 86400))" +%Y-%m-%d)
    TOMORROW=$(date -jf "%s" "$((ANCHOR_EPOCH + 86400))" +%Y-%m-%d)

    CHANGED=false
    TEMP_FILE="${f}.tmp.$$"

    IN_FRONTMATTER=false
    FM_COUNT=0
    while IFS= read -r line; do
      if [[ "$line" == "---" ]]; then
        FM_COUNT=$((FM_COUNT + 1))
        if [[ "$FM_COUNT" -le 2 ]]; then
          IN_FRONTMATTER=true
          [[ "$FM_COUNT" -eq 2 ]] && IN_FRONTMATTER=false
        fi
        printf '%s\n' "$line" >> "$TEMP_FILE"
        continue
      fi

      if [[ "$IN_FRONTMATTER" == "false" ]] && [[ "$FM_COUNT" -ge 2 ]]; then
        if echo "$line" | grep -qE '"[^"]*\b(yesterday|today|tomorrow)\b[^"]*"'; then
          printf '%s\n' "$line" >> "$TEMP_FILE"
          continue
        fi

        ORIG="$line"
        # Portable word boundary: BSD sed treats `\b` as a literal backspace (a silent
        # no-op on macOS), so anchor on non-alphanumeric capture groups (valid on BOTH
        # BSD and GNU sed). \1/\3 re-emit the surrounding boundary chars; the plural
        # (`yesterdays`) is spared because its trailing char is alphanumeric.
        line=$(echo "$line" | sed -E "s/(^|[^[:alnum:]])(yesterday)([^[:alnum:]]|\$)/\1$YESTERDAY\3/gi")
        line=$(echo "$line" | sed -E "s/(^|[^[:alnum:]])(today)([^[:alnum:]]|\$)/\1$ANCHOR\3/gi")
        line=$(echo "$line" | sed -E "s/(^|[^[:alnum:]])(tomorrow)([^[:alnum:]]|\$)/\1$TOMORROW\3/gi")

        if [[ "$line" != "$ORIG" ]]; then
          CHANGED=true
          TEMPORAL_FIXES=$((TEMPORAL_FIXES + 1))
        fi
      fi

      printf '%s\n' "$line" >> "$TEMP_FILE"
    done < "$f"

    if [[ "$CHANGED" == "true" ]]; then
      mv "$TEMP_FILE" "$f"
    else
      rm -f "$TEMP_FILE"
    fi
  fi
done

# --- Check 8: Budget monitor (defect 2: byte-first, both-raw-and-stripped) ---
# Compute RAW line count, BYTE count, char-line count, and a comment-stripped
# raw line count; gate on the LARGER ratio. The byte cap is the governing
# trigger (.5/).
LINE_COUNT=0
STRIPPED_LINE_COUNT=0
BYTE_COUNT=0
LONG_LINES=0
if [[ -f "$INDEX_FILE" ]]; then
  LINE_COUNT=$(wc -l < "$INDEX_FILE" | tr -d ' ')
  BYTE_COUNT=$(wc -c < "$INDEX_FILE" | tr -d ' ')

  # Comment-stripped raw line count: drop HTML-comment blocks (<!-- ... -->),
  # then count remaining lines. Gate on the LARGER of raw vs stripped (the
  # stripped count may be smaller; we keep the larger so comments never buy
  # unlimited headroom —.5 "gate on the larger").
  STRIPPED_LINE_COUNT=$(awk '
    /<!--/ { inc=1 }
    inc==0 { print }
    /-->/ { inc=0 }
  ' "$INDEX_FILE" | wc -l | tr -d ' ')

  # Longest-line guard (char-line cap).
  LONG_LINES=$(awk -v cap="$CAP_CHAR_LINE" 'length > cap { n++ } END { print n+0 }' "$INDEX_FILE")

  # Effective line count = the LARGER of raw and comment-stripped.
  EFFECTIVE_LINES="$LINE_COUNT"
  [[ "$STRIPPED_LINE_COUNT" -gt "$EFFECTIVE_LINES" ]] && EFFECTIVE_LINES="$STRIPPED_LINE_COUNT"

  LINE_PCT=$(( EFFECTIVE_LINES * 100 / CAP_LINES ))
  BYTE_PCT=$(( BYTE_COUNT * 100 / CAP_BYTES ))

  # The byte cap is the governing trigger: gate on the larger of byte% and line%.
  PCT="$LINE_PCT"
  [[ "$BYTE_PCT" -gt "$PCT" ]] && PCT="$BYTE_PCT"

  if [[ "$PCT" -ge 90 || "$LONG_LINES" -gt 0 ]]; then
    BUDGET_STATUS="RED"
  elif [[ "$PCT" -ge 75 ]]; then
    BUDGET_STATUS="YELLOW"
  else
    BUDGET_STATUS="GREEN"
  fi
fi

# --- Write consolidation log ---
END_TIME=$(date +%s)
DURATION_MS=$(( (END_TIME - START_TIME) * 1000 ))

TOTAL=$(jq -r '.total_consolidations // 0' "$STATE_FILE")
TOTAL=$((TOTAL + 1))

cat >> "$LOG_FILE" <<EOF

## Consolidation ${TOTAL} — $(date +"%Y-%m-%d %H:%M")
- Files scanned: ${FILES_SCANNED}
- Stale files flagged (180-360d → propose revalidate): ${STALE_FLAGGED}
- Expired files flagged (≥360d → propose revalidate|supersede|archive): ${EXPIRED_FLAGGED}
- Orphans added to index: ${ORPHANS_ADDED}
- Dead references removed: ${DEAD_REFS_REMOVED}
- Temporal fixes applied: ${TEMPORAL_FIXES}
- Budget status: ${BUDGET_STATUS} (raw ${LINE_COUNT}L / stripped ${STRIPPED_LINE_COUNT}L / ${BYTE_COUNT}B; caps ${CAP_LINES}L/${CAP_BYTES}B; long-lines ${LONG_LINES})
- Duration: ${DURATION_MS}ms
EOF

# Visible degradation (fail-open preserved): when the declared foundation
# thresholds were NOT applied this run, say so in the durable log — a silent
# fallback reads as a healthy run and hides a stale-caps divergence.
if [[ "$CAP_SOURCE" != "bundle" ]]; then
  printf -- '- Cap-config DEGRADED: fallback caps %sL/%sB/%sC applied — %s. The declared foundation thresholds (mandatory_files.mandates._memory_md_cap.thresholds) were not applied this run.\n' \
    "$CAP_LINES" "$CAP_BYTES" "$CAP_CHAR_LINE" "$CAP_DEGRADE_CAUSE" >> "$LOG_FILE"
fi

# --- Update state ---
jq \
  --arg ts "$NOW_ISO" \
  --argjson total "$TOTAL" \
  '.last_consolidation = $ts | .sessions_since = 0 | .total_consolidations = $total | .last_result = "success" | .last_error = null' \
  "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

exit 0
