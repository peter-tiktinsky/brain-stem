#!/usr/bin/env bash
# brief-lint.sh — T-1 — Pre-dispatch brief-quality lint (advisory).
# Invoked from dispatch.sh pre-flight, post-brief-meta validation. Calls Haiku
# 4.5 via `claude -p` to score brief quality across five dimensions:
#   - vague objectives (no concrete deliverable shape)
#   - under-specified expected_artifacts paths
#   - missing acceptance criteria shape
#   - token-asymmetric scope (one task >>> sibling tasks)
#   - inconsistent themes
# Output is advisory ONLY — never blocks dispatch. Exit 0 always.
# Self-contained: sources NO project .sh lib; shells out to claude / jq /
# python3 only (each graceful-degrades). Decoupled from the 3 DEFER surfaces
# (governance.sh caps, retry-dispatch.sh, the verifier ENHANCEMENT).
# Usage:
#   brief-lint.sh <brief-path>
# Env vars:
#   ORCHESTRATOR_BRIEF_LINT         — "1" to enable; unset/empty = OFF (default OFF per rollout)
#   ORCHESTRATOR_BRIEF_LINT_MODEL   — model name (default: claude-haiku-4-5)
#   ORCHESTRATOR_BRIEF_LINT_BUDGET  — claude -p --max-budget-usd ceiling (default: 0.25)
#   ORCHESTRATOR_STATE_DIR          — state dir override (default: $CLAUDE_STATE_ROOT/runtime)
#   CLAUDE_HOME                     — install root (default: ~/.claude)
#   CLAUDE_BIN                      — claude binary override (default: claude on PATH)
# Cost log (append-only JSONL):
#   $ORCHESTRATOR_STATE_DIR/governance/brief-lint-cost.jsonl
# 5-dispatch sample validation gate:
#   Sum of last 5 cost entries divided by 5 must be ≤ $0.005/dispatch.
#   Query post-hoc:
#     tail -n 5 .../brief-lint-cost.jsonl | jq -s 'map(.cost) | add / length'
# Exit codes:
#   0   — always (advisory; including degraded-API and feature-flag-OFF cases)

# Advisory contract: exit 0 on all paths. Use -u + pipefail but NOT -e
# (-e aborts mid-script on any transient failure, violating the contract).
set -uo pipefail

BRIEF="${1:-}"
if [[ -z "$BRIEF" ]]; then
  echo "Usage: brief-lint.sh <brief-path>" >&2
  exit 0
fi
if [[ ! -f "$BRIEF" ]]; then
  echo "[brief-lint] brief not found: $BRIEF (advisory; not blocking)" >&2
  exit 0
fi

# --- Feature flag gate ---
if [[ "${ORCHESTRATOR_BRIEF_LINT:-}" != "1" ]]; then
  exit 0
fi

# --- Locations + defaults ---
STATE_DIR="${ORCHESTRATOR_STATE_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/runtime}"
GOVERNANCE_DIR="$STATE_DIR/governance"
COST_LOG="$GOVERNANCE_DIR/brief-lint-cost.jsonl"
MODEL="${ORCHESTRATOR_BRIEF_LINT_MODEL:-claude-haiku-4-5}"
BUDGET="${ORCHESTRATOR_BRIEF_LINT_BUDGET:-0.25}"
CLAUDE="${CLAUDE_BIN:-claude}"

mkdir -p "$GOVERNANCE_DIR"

# --- Build prompt ---
# Read brief content; cap at 16KB so a pathological brief can't blow the cost cap.
# Typical brief is 2-8KB. Truncation triggers a separate finding.
BRIEF_BYTES=$(wc -c < "$BRIEF" | tr -d ' ')
TRUNCATED="false"
if (( BRIEF_BYTES > 16384 )); then
  BRIEF_TEXT=$(head -c 16384 "$BRIEF")
  TRUNCATED="true"
else
  BRIEF_TEXT=$(cat "$BRIEF")
fi

PROMPT="You are a pre-dispatch brief-quality auditor for an autonomous-agent dispatch system. Assess the brief below for these five failure modes:

1. vague objectives (no concrete deliverable shape)
2. under-specified expected_artifacts paths (declared but no acceptance criteria / line counts / regex matchers)
3. missing acceptance criteria shape (no measurable success bar)
4. token-asymmetric scope (one task >>> sibling tasks; ~10x imbalance)
5. inconsistent themes (multiple unrelated objectives crammed together)

Respond with VALID JSON ONLY — no preamble, no markdown fence, no commentary. Schema:

{
  \"score\": <integer 1-5; 5=excellent, 1=unfit for dispatch>,
  \"findings\": [
    {\"severity\": \"info\"|\"warn\"|\"error\", \"code\": \"<short-code>\", \"message\": \"<one-sentence>\"}
  ],
  \"advisory\": \"<one-paragraph synthesis>\"
}

Empty findings list is OK for high-quality briefs. Brief truncated for cost cap: $TRUNCATED.

Brief:
<<<
$BRIEF_TEXT
>>>"

# --- Invoke claude -p ---
TS_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/brief-lint-out.XXXXXX")
trap 'rm -f "$OUTPUT_FILE"' EXIT

CLAUDE_ARGS=(
  -p "$PROMPT"
  --model "$MODEL"
  --output-format json
  --max-budget-usd "$BUDGET"
)

CLAUDE_RC=0
"$CLAUDE" "${CLAUDE_ARGS[@]}" > "$OUTPUT_FILE" 2>&1 || CLAUDE_RC=$?

# --- Parse result ---
# claude -p emits one JSON-result line; SessionEnd hooks can append non-JSON
# text after it (job-runner.sh result-line extraction pattern).
JSON_LINE=$(grep -m1 '^{"type":"result"' "$OUTPUT_FILE" 2>/dev/null || true)
if [[ -z "$JSON_LINE" ]] && head -n 1 "$OUTPUT_FILE" 2>/dev/null | jq empty 2>/dev/null; then
  JSON_LINE=$(head -n 1 "$OUTPUT_FILE")
fi

COST="0"
NUM_TURNS="0"
SESSION_ID=""
RESULT_TEXT=""
if [[ -n "$JSON_LINE" ]] && echo "$JSON_LINE" | jq empty 2>/dev/null; then
  COST=$(echo "$JSON_LINE" | jq -r '(.total_cost_usd // .cost_usd // 0)' 2>/dev/null || echo "0")
  NUM_TURNS=$(echo "$JSON_LINE" | jq -r '.num_turns // 0' 2>/dev/null || echo "0")
  SESSION_ID=$(echo "$JSON_LINE" | jq -r '.session_id // ""' 2>/dev/null || echo "")
  RESULT_TEXT=$(echo "$JSON_LINE" | jq -r '.result // ""' 2>/dev/null || echo "")
fi

# --- Cost log (append-only JSONL) ---
TS_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
COST_ENTRY=$(jq -nc \
  --arg ts "$TS_END" \
  --arg ts_start "$TS_START" \
  --arg brief "$BRIEF" \
  --arg model "$MODEL" \
  --argjson cost "${COST:-0}" \
  --argjson turns "${NUM_TURNS:-0}" \
  --arg session "$SESSION_ID" \
  --argjson rc "$CLAUDE_RC" \
  --arg trunc "$TRUNCATED" \
  --argjson brief_bytes "$BRIEF_BYTES" \
  '{
    ts: $ts,
    ts_start: $ts_start,
    brief: $brief,
    model: $model,
    cost: $cost,
    num_turns: $turns,
    session_id: $session,
    claude_rc: $rc,
    brief_truncated: ($trunc == "true"),
    brief_bytes: $brief_bytes
  }')
printf '%s\n' "$COST_ENTRY" >> "$COST_LOG"

# --- Emit advisory ---
echo ""
echo "================================================================"
echo "[brief-lint] T-1 — brief-quality advisory ($(basename "$BRIEF"))"
echo "================================================================"
if (( CLAUDE_RC != 0 )); then
  echo "[brief-lint] claude -p exited rc=$CLAUDE_RC; degraded — proceeding with dispatch (advisory only)"
  echo "[brief-lint] cost logged: \$$COST | model: $MODEL"
  echo "================================================================"
  exit 0
fi

# Try to parse RESULT_TEXT as the JSON payload from Haiku.
# Haiku sometimes wraps JSON in prose; extract first {...} block.
LINT_JSON=""
if [[ -n "$RESULT_TEXT" ]]; then
  # Strip optional ```json fences
  CLEANED=$(printf '%s' "$RESULT_TEXT" | sed -E 's/^```(json)?$//; s/```$//' )
  if echo "$CLEANED" | jq empty 2>/dev/null; then
    LINT_JSON="$CLEANED"
  else
    # Extract first balanced { ... } block via python (no awk-state-machine pain)
    LINT_JSON=$(python3 -c '
import json, re, sys
text = sys.stdin.read()
# Find first { ... } that parses.
for m in re.finditer(r"\{", text):
    for end in range(len(text), m.start(), -1):
        chunk = text[m.start():end]
        try:
            json.loads(chunk)
            print(chunk)
            sys.exit(0)
        except Exception:
            continue
sys.exit(1)
' <<< "$RESULT_TEXT" 2>/dev/null || echo "")
  fi
fi

if [[ -z "$LINT_JSON" ]] || ! echo "$LINT_JSON" | jq empty 2>/dev/null; then
  echo "[brief-lint] could not parse lint response as JSON; raw result:"
  echo "$RESULT_TEXT" | head -c 500
  echo ""
  echo "[brief-lint] cost logged: \$$COST | model: $MODEL"
  echo "================================================================"
  exit 0
fi

SCORE=$(echo "$LINT_JSON" | jq -r '.score // "?"')
ADVISORY=$(echo "$LINT_JSON" | jq -r '.advisory // ""')
FINDINGS_COUNT=$(echo "$LINT_JSON" | jq -r '.findings | length // 0')

echo "Score: $SCORE/5 | Findings: $FINDINGS_COUNT | Cost: \$$COST | Model: $MODEL"
if (( FINDINGS_COUNT > 0 )); then
  echo ""
  echo "Findings:"
  echo "$LINT_JSON" | jq -r '.findings[] | "  [\(.severity | ascii_upcase)] \(.code): \(.message)"'
fi
if [[ -n "$ADVISORY" ]]; then
  echo ""
  echo "Advisory:"
  echo "  $ADVISORY"
fi
if [[ "$TRUNCATED" == "true" ]]; then
  echo ""
  echo "[brief-lint] brief truncated to 16KB for cost cap (original: ${BRIEF_BYTES} bytes)"
fi
echo "================================================================"
exit 0
