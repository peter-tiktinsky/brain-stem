#!/bin/bash
# Hook: spec-context-inject — Inject the active plan's spec authority as context.
#
# PRIMARY firing: SessionStart (+ source:compact). The goal-anchor lands from turn 1
# and re-fires after compaction (fixing post-compaction instruction loss). The
# UserPromptSubmit slot is RETAINED for (a) picking up a mid-session arming (the
# pointer chain resolves fresh each prompt; the sentinel dedupes repeats) and
# (b) cross-plan prompt disambiguation in UNARMED sessions only. This body handles
# plan-execution context, not session orchestration.
# Behavior: master/sub plans are first-class (the master-spec payload is
# load-bearing); the canonical status vocabulary gates firing; agent-reload
# loads non-superseded decision_records[].
#
# Trigger: keys on the canonical `status == in-progress` (re-points off the
# retired top_level_status). The hook fires for in-progress plans the foundation ships;
# completed/superseded/etc. plans are skipped.
#
# 3-way payload dispatch:
#   flat  -> own spec head + manifest AC + non-superseded decision_records[]
#   sub   -> own spec head + AC + master spec head + master sub_plans[] sibling-status
#            + master dependencies + non-superseded decision_records[]
#   master-> own spec head + sub_plans[] rollup + non-superseded decision_records[]
#
# Sentinel keyed (session x plan x source) so a compaction re-fires (a fresh
# source:compact gets a distinct sentinel from the original source:startup).
#
# Injected text is FACTUAL, not imperative ("The authoritative spec for the active
# plan is <path>. ...") per + Anthropic hooks prompt-injection guidance.
#
# Fail-open: silent on any error; never blocks. Size-capped below the hook-output
# validator bound. Bash 3.2 clean (R-23). $SCRIPT_DIR/lib sourcing (portable;
# NO literal $HOME/.claude path in the body).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/registry.sh"

PLANS_DIR="${PLANS_DIR:-$HOME/.claude-plans}"

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

[[ -z "$SESSION_ID" ]] && exit 0
[[ ! -d "$PLANS_DIR" ]] && exit 0

# Resolve the event when absent (defensive): a prompt present => UserPromptSubmit.
if [[ -z "$EVENT" ]]; then
  if [[ -n "$PROMPT" ]]; then EVENT="UserPromptSubmit"; else EVENT="SessionStart"; fi
fi

# Plan resolution
# A "plan target" is a plan-tree directory: either a flat/master plan dir
# (NN-slug) or a sub-plan dir (NN-slug/NN-subslug | NN-slug/SP-NN-subslug).
# Resolution is arm-pointer-FIRST on BOTH events: the
# arming chain ($PLANS_DIR/.active-plan -> <plan>/.active-sp) is the SoT for
# "the active plan"; when it resolves, it wins. The heuristics survive ONLY as
# the unarmed fallback:
#   SessionStart:     discover the single in-progress plan (goal-anchor).
#   UserPromptSubmit: fire for a plan explicitly referenced in the prompt
#                     (cross-plan disambiguation).
# A prompt that merely REFERENCES a different plan must never be injected as
# "the active plan" over an armed one — that is the wrong-framing vector
# (bystander plan Y's spec labeled authoritative while armed mid-build on X).

PLAN_REL=""   # path relative to $HOME, e.g. .claude-plans/93-foo OR .claude-plans/93-foo/-bar

resolve_from_prompt() {
  local rel
  # Signal 1: explicit sub-plan path in the prompt
  rel=$(printf '%s\n' "$PROMPT" | grep -oE '\.claude-plans/[0-9]{2,}-[a-z0-9-]+/(SP-)?[0-9]{2,}-[a-z0-9-]+' | head -1 || true)
  if [[ -z "$rel" ]]; then
    # Signal 1b: explicit top-level plan path
    rel=$(printf '%s\n' "$PROMPT" | grep -oE '\.claude-plans/[0-9]{2,}-[a-z0-9-]+' | head -1 || true)
  fi
  if [[ -z "$rel" ]]; then
    # Signal 2: "Plan N SPM" framing + slug existence
    local plan_num sp_num plan_dir sp_padded sp_dir
    plan_num=$(printf '%s\n' "$PROMPT" | grep -oiE 'Plan +[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
    sp_num=$(printf '%s\n' "$PROMPT" | grep -oiE 'SP[- ]?[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
    if [[ -n "$plan_num" ]]; then
      plan_dir=$(find "$PLANS_DIR" -maxdepth 1 -type d -name "${plan_num}-*" 2>/dev/null | head -1)
      if [[ -n "$plan_dir" ]]; then
        if [[ -n "$sp_num" ]]; then
          sp_padded=$(printf "%02d" $((10#$sp_num)))
          sp_dir=$(find "$plan_dir" -maxdepth 1 -type d \( -name "${sp_padded}-*" -o -name "SP-${sp_padded}-*" \) 2>/dev/null | head -1)
          if [[ -n "$sp_dir" ]]; then
            rel=".claude-plans/$(basename "$plan_dir")/$(basename "$sp_dir")"
          else
            rel=".claude-plans/$(basename "$plan_dir")"
          fi
        else
          rel=".claude-plans/$(basename "$plan_dir")"
        fi
      fi
    fi
  fi
  printf '%s' "$rel"
}

# manifest status reader (fail-open empty).
manifest_status() {
  local mf="$1"
  [[ -f "$mf" ]] || { printf ''; return; }
  jq -r '.status // ""' "$mf" 2>/dev/null || printf ''
}

# Resolve the ARMED plan target from the arm-pointer chain:
# $PLANS_DIR/.active-plan names the armed plan; <plan>/.active-sp names the
# armed sub ('.' = the plan's own root manifest). Prints the rel target, or
# empty when unarmed. A dangling .active-plan (no such dir) degrades to
# unarmed; a dangling/absent .active-sp degrades to the plan ROOT — the plan
# pointer is still meaningful, and falling back to a heuristic there would
# reopen the bystander vector this function exists to close.
resolve_from_arm_pointers() {
  local ap="$PLANS_DIR/.active-plan" plan sp rel
  [[ -f "$ap" ]] || { printf ''; return; }
  plan=$(tr -d '[:space:]' < "$ap" 2>/dev/null || true)
  if [[ -z "$plan" || ! -d "$PLANS_DIR/$plan" ]]; then printf ''; return; fi
  rel=".claude-plans/$plan"
  if [[ -f "$PLANS_DIR/$plan/.active-sp" ]]; then
    sp=$(tr -d '[:space:]' < "$PLANS_DIR/$plan/.active-sp" 2>/dev/null || true)
    if [[ -n "$sp" && "$sp" != "." && -d "$PLANS_DIR/$plan/$sp" ]]; then
      rel=".claude-plans/$plan/$sp"
    fi
  fi
  printf '%s' "$rel"
}

# Discover the single in-progress plan target. Prefers a sub-plan over its master
# when the sub is the in-progress one (most-specific active scope). Returns the
# first match; if multiple in-progress plans exist, SessionStart stays silent (the
# UPS disambiguation slot handles the ambiguous case on the next prompt).
discover_in_progress() {
  local hits=0 found="" plan_dir sp_dir st
  for plan_dir in "$PLANS_DIR"/[0-9]*-*; do
    [[ -d "$plan_dir" ]] || continue
    # sub-plan dirs first (most specific)
    for sp_dir in "$plan_dir"/[0-9]*-* "$plan_dir"/SP-[0-9]*-*; do
      [[ -d "$sp_dir" ]] || continue
      st=$(manifest_status "$sp_dir/manifest.json")
      if [[ "$st" == "in-progress" ]]; then
        hits=$((hits + 1)); found=".claude-plans/$(basename "$plan_dir")/$(basename "$sp_dir")"
      fi
    done
    st=$(manifest_status "$plan_dir/manifest.json")
    if [[ "$st" == "in-progress" ]]; then
      hits=$((hits + 1)); found=".claude-plans/$(basename "$plan_dir")"
    fi
  done
  # exactly one in-progress target -> anchor it; else stay silent (ambiguous/none)
  if [[ "$hits" -eq 1 ]]; then printf '%s' "$found"; fi
}

# Pointer-first on BOTH events: an armed chain wins; the per-event
# heuristics below fire only when the chain does not resolve (unarmed).
ARMED_REL=$(resolve_from_arm_pointers)
if [[ "$EVENT" == "UserPromptSubmit" ]]; then
  [[ -z "$PROMPT" ]] && exit 0
  PLAN_REL="$ARMED_REL"
  [[ -z "$PLAN_REL" ]] && PLAN_REL=$(resolve_from_prompt)
  [[ -z "$PLAN_REL" ]] && exit 0
else
  # SessionStart (+ source:compact, resume, startup)
  PLAN_REL="$ARMED_REL"
  [[ -z "$PLAN_REL" ]] && PLAN_REL=$(discover_in_progress)
  [[ -z "$PLAN_REL" ]] && exit 0
fi

TARGET_ABS="$HOME/$PLAN_REL"
[[ -d "$TARGET_ABS" ]] || exit 0
[[ -f "$TARGET_ABS/spec.md" ]] || exit 0

TARGET_MANIFEST="$TARGET_ABS/manifest.json"

# Terminal-skip exit-case keyed on the canonical 6-state vocabulary: a terminal
# plan gets no active-context injection. The terminal set is {completed, superseded}
# (completed is the sole terminal done-state; superseded is the off-ramp). The hook
# reads `.status` (NOT the retired top_level_status alias).
TARGET_STATUS=$(manifest_status "$TARGET_MANIFEST")
case "$TARGET_STATUS" in
  completed|superseded) exit 0 ;;
esac

# Determine the plan TYPE for the 3-way dispatch.
#   sub-plan : the target rel path has a sub-plan segment (master/SUB) OR manifest type==sub-plan
#   master   : manifest type==master
#   flat     : otherwise (type:plan)
PLAN_TYPE="flat"
MANIFEST_TYPE=$(jq -r '.type // ""' "$TARGET_MANIFEST" 2>/dev/null || printf '')
case "$MANIFEST_TYPE" in
  sub-plan) PLAN_TYPE="sub" ;;
  master)   PLAN_TYPE="master" ;;
  *)
    # fall back to structural detection: a sub-plan dir lives one level under a plan dir
    if printf '%s' "$PLAN_REL" | grep -qE '^\.claude-plans/[0-9]{2,}-[a-z0-9-]+/(SP-)?[0-9]{2,}-[a-z0-9-]+$'; then
      PLAN_TYPE="sub"
    fi
    ;;
esac

PLAN_SLUG=$(basename "$TARGET_ABS")
case "$PLAN_TYPE" in
  sub) MASTER_ABS="$(dirname "$TARGET_ABS")"; MASTER_SLUG="$(basename "$MASTER_ABS")" ;;
  *)   MASTER_ABS=""; MASTER_SLUG="" ;;
esac

# Sentinel: (session x plan x source). A fresh compaction (source:compact) gets a
# distinct sentinel from the original startup so it re-fires after compaction.
STATE_DIR="$CLAUDE_STATE_ROOT/spec-context-inject"
SENTINEL_KEY="${SESSION_ID:0:8}-$(printf '%s' "$PLAN_REL" | tr '/.' '__')-${SOURCE}"
SENTINEL="$STATE_DIR/$SENTINEL_KEY.flag"
[[ -f "$SENTINEL" ]] && exit 0

# Context build — FACTUAL framing.
emit_decision_records() {
  # (T-12): on plan resume, load NON-superseded ADRs via the manifest pointer
  # manifest.decision_records[] (refinement #4). Filters out status
  # superseded/deprecated entries. Graceful no-op when absent/empty.
  local mf="$1" recs
  [[ -f "$mf" ]] || return
  recs=$(jq -r '
    (.decision_records // [])
    | map(select((.status // "") != "superseded" and (.status // "") != "deprecated"))
    | .[]? | "- \(.id): \(.title) [\(.status // "?")] -> \(.path // "?")"
  ' "$mf" 2>/dev/null || true)
  if [[ -n "$recs" ]]; then
    context+="
### Active decision records (non-superseded ADRs, via \`manifest.decision_records[]\`)

$recs
"
  fi
}

context="## SPEC AUTHORITY — active plan: \`$PLAN_REL\` ($PLAN_TYPE)

The authoritative spec for the active plan is \`$PLAN_REL/spec.md\`. The spec ranks above any operational brief; if a brief and the spec disagree, the spec is authoritative and the brief is treated as defective. Framing claims should be grounded in spec text (cite line numbers in close-out summaries).

### \`$PLAN_SLUG/spec.md\` — first 80 lines
"
context+='```'$'\n'
context+="$(head -80 "$TARGET_ABS/spec.md" 2>/dev/null || echo '(unreadable)')"
context+=$'\n''```'$'\n'

# own manifest: status, deps, AC
if [[ -f "$TARGET_MANIFEST" ]]; then
  context+="
### \`$PLAN_SLUG/manifest.json\` — status, deps, AC
"
  context+='```json'$'\n'
  context+="$(jq '{status, type, schema_version, parent_plan, sub_plan_id, dependencies, tasks: ([.tasks[]? | {id, title, status, depends_on, acceptance_criteria}] // [])}' "$TARGET_MANIFEST" 2>/dev/null | head -120 || echo '{}')"
  context+=$'\n''```'$'\n'
fi

# agent-reload: own decision_records[]
emit_decision_records "$TARGET_MANIFEST"

# 3-way payload dispatch additions
case "$PLAN_TYPE" in
  sub)
    # sub -> + master spec head + master sub_plans[] sibling-status + master dependencies.
    # The master sub_plans[] is's read-replica (subplan-aggregate.sh output),
    # read directly from the master manifest (reverse-read edge).
    if [[ -n "$MASTER_ABS" && -f "$MASTER_ABS/spec.md" ]]; then
      context+="
### \`$MASTER_SLUG/spec.md\` (master) — first 50 lines
"
      context+='```'$'\n'
      context+="$(head -50 "$MASTER_ABS/spec.md" 2>/dev/null)"
      context+=$'\n''```'$'\n'
    fi
    if [[ -n "$MASTER_ABS" && -f "$MASTER_ABS/manifest.json" ]]; then
      context+="
### \`$MASTER_SLUG/manifest.json\` — sibling status (\`sub_plans[]\`) + cross-plan \`dependencies\`
"
      context+='```json'$'\n'
      context+="$(jq '{sub_plans: (.sub_plans // []), dependencies: (.dependencies // {})}' "$MASTER_ABS/manifest.json" 2>/dev/null | head -80 || echo '{}')"
      context+=$'\n''```'$'\n'
    fi
    ;;
  master)
    # master -> + sub_plans[] rollup (own read-replica)
    if [[ -f "$TARGET_MANIFEST" ]]; then
      context+="
### \`$PLAN_SLUG/manifest.json\` — sub-plan status rollup (\`sub_plans[]\`)
"
      context+='```json'$'\n'
      context+="$(jq '{sub_plans: (.sub_plans // [])}' "$TARGET_MANIFEST" 2>/dev/null | head -80 || echo '{}')"
      context+=$'\n''```'$'\n'
    fi
    ;;
esac

context+="
The full \`spec.md\` (and \`00-ideation-brief.md\` if present) is the source of truth for scope, sequencing, and dependency questions."

# Size-cap below the hook-output validator bound (mechanism research-validated).
ctx_bytes=$(printf '%s' "$context" | wc -c | tr -d ' ')
if [[ "$ctx_bytes" -gt 9728 ]]; then
  context=$(printf '%s' "$context" | head -c 9500)
  context+="

[truncated at 9.5KB to fit the hook-output validator cap — read the full files directly for more]"
fi

# Emit. Fail-open: a validator-reject suppresses the emission but does NOT block.
if format_output "$EVENT" "$context"; then
  mkdir -p "$STATE_DIR"
  touch "$SENTINEL"
  exit 0
else
  exit 0
fi
