#!/bin/bash
# Hook: spec-context-inject — Inject the active plan's spec authority as context.
#
# PRIMARY firing: SessionStart (+ source:compact). The goal-anchor lands from turn 1
# and re-fires after compaction (fixing post-compaction instruction loss). The
# UserPromptSubmit slot is RETAINED for (a) picking up a mid-session arming (the
# pointer chain resolves fresh each prompt; the sentinel dedupes repeats) and
# (b) cross-plan prompt disambiguation in UNARMED sessions only. This body handles
# plan-execution context, not session orchestration.
#
# LAUNCH-SPOKE KEYED. The plan injected is the one armed in THIS session's launch
# spoke and no other. The payload `.cwd` is resolved to a spoke key through the shared
# cwd->spoke resolver (skills/new-plan/lib/spoke-resolve.sh — the same resolver the
# situating card keys on), and the arm pointer is read for that spoke
# (hooks/lib/active-plan-resolve.sh). A plan armed for another spoke is never injected
# here, and the unarmed fallbacks below are scoped to the same spoke. A launch dir
# under no registered anchor is the `home` catch-all, which reads the plan corpus
# unfiltered — a single-spoke install sees no behaviour change.
#
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
# Fail-open: silent on any error; never blocks — including every step of the spoke
# resolution, which degrades to `home` rather than erroring. Size-capped below the
# hook-output validator bound. Bash 3.2 clean (R-23). $SCRIPT_DIR/lib sourcing (
# portable; NO literal $HOME/.claude path in the body).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/registry.sh"

PLANS_DIR="${PLANS_DIR:-$HOME/.claude-plans}"

# Read the payload (hook_event_name + session_id + cwd).
# BOUNDED capture: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook hangs with zero output. The timeout
# is on EVERY read and each line accumulates as it arrives, so a stream that keeps
# delivering is never truncated; blank lines are PRESERVED and the trailing-newline
# trim reproduces `$(cat)` exactly, so the payload reaches jq byte-identical.
# HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
# The two reference implementations under skills/librarian/capabilities/ are NOT
# equivalent and this is neither: handoff-disposition-check.sh re-arms per read but
# DROPS blank lines; rename-cascade.sh bounds only the FIRST read, then free-runs an
# unbounded `cat`. This is the byte-preserving form the other hook drains carry.
INPUT=""
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE || [ -n "$_STDIN_LINE" ]; do
    INPUT="${INPUT}${_STDIN_LINE}"$'\n'
    _STDIN_LINE=""
  done
  while [ "${INPUT%$'\n'}" != "$INPUT" ]; do INPUT="${INPUT%$'\n'}"; done
  unset _STDIN_WAIT _STDIN_LINE
fi
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')
# The launch dir, present on BOTH events. Guarded: an unreadable payload field is a
# `home` resolution below, never a non-zero exit.
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || printf '')

[[ -z "$SESSION_ID" ]] && exit 0
[[ ! -d "$PLANS_DIR" ]] && exit 0

# Resolve the event when absent (defensive): a prompt present => UserPromptSubmit.
if [[ -z "$EVENT" ]]; then
  if [[ -n "$PROMPT" ]]; then EVENT="UserPromptSubmit"; else EVENT="SessionStart"; fi
fi

# Launch spoke — the session identity every resolution below is keyed to
# The shared cwd->spoke resolver maps the launch dir to a registry spoke key. The
# repo-local copy is sourced first (dev/test), then the live install — the same
# two-candidate loop the situating-card hook uses. EVERY failure mode (no `.cwd`, no
# resolver on disk, a registry collision, an empty result) degrades to the `home`
# catch-all, which reads the corpus exactly as an un-migrated single-spoke install
# does. This hook never blocks, so an unresolvable spoke must never be an error.
for _sr in "$SCRIPT_DIR/../skills/new-plan/lib/spoke-resolve.sh" \
           "${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/spoke-resolve.sh"; do
  if [[ -r "$_sr" ]]; then
    # shellcheck source=/dev/null
    source "$_sr" 2>/dev/null || true
    break
  fi
done
unset _sr

SPOKE="home"
if [[ -n "$CWD" ]] && command -v spoke_resolve_from_cwd >/dev/null 2>&1; then
  SPOKE=$(spoke_resolve_from_cwd "$CWD" 2>/dev/null || printf '')
  [[ -n "$SPOKE" ]] || SPOKE="home"
fi

# The per-spoke arm-pointer resolver, from the same lib dir registry.sh came from.
# Guarded on both source and call: an install without it resolves nothing as armed and
# the spoke-scoped unarmed fallbacks below carry the hook.
if [[ -r "$SCRIPT_DIR/lib/active-plan-resolve.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/active-plan-resolve.sh" 2>/dev/null || true
fi

# Plan resolution
# A "plan target" is a plan-tree directory: either a flat/master plan dir
# (NN-slug) or a sub-plan dir (NN-slug/NN-subslug | NN-slug/SP-NN-subslug).
# Resolution is arm-pointer-FIRST on BOTH events, and the pointer is
# THIS SPOKE'S: the arming chain ($PLANS_DIR/_projects/$SPOKE/.active-plan ->
# <plan>/.active-sp, with the corpus-wide legacy pointer as the read-only fallback
# described in hooks/lib/active-plan-resolve.sh) is the SoT for "the active plan";
# when it resolves, it wins. The heuristics survive ONLY as the unarmed fallback, and
# they are scoped to the same spoke:
#   SessionStart:     discover the single in-progress plan OF THIS SPOKE (goal-anchor).
#   UserPromptSubmit: fire for a plan explicitly referenced in the prompt, and only
#                     when that plan belongs to this spoke (cross-plan disambiguation).
# A prompt that merely REFERENCES a different plan must never be injected as
# "the active plan" over an armed one — that is the wrong-framing vector
# (bystander plan Y's spec labeled authoritative while armed mid-build on X). A plan
# belonging to ANOTHER spoke is not this session's active plan at all, whichever leg
# surfaces it. For the `home` catch-all every leg reads the corpus unfiltered.

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

# manifest project (owning spoke key) reader (fail-open empty).
manifest_project() {
  local mf="$1"
  [[ -f "$mf" ]] || { printf ''; return; }
  jq -r '.project // ""' "$mf" 2>/dev/null || printf ''
}

# Does a plan owned by <project> belong to this session's spoke? The `home` catch-all
# takes every plan (legacy, corpus-wide); a registered spoke takes only its own.
spoke_matches_project() {
  if [[ "$SPOKE" == "home" ]]; then return 0; fi
  if [[ "$1" == "$SPOKE" ]]; then return 0; fi
  return 1
}

# Same question for a resolved rel target: a sub-plan with no `project` of its own
# inherits its master's.
spoke_owns_target() {
  local rel="$1" abs proj
  if [[ "$SPOKE" == "home" ]]; then return 0; fi
  abs="$PLANS_DIR/${rel#.claude-plans/}"
  proj=$(manifest_project "$abs/manifest.json")
  [[ -n "$proj" ]] || proj=$(manifest_project "$(dirname "$abs")/manifest.json")
  spoke_matches_project "$proj"
}

# Discover the single in-progress plan target OF THIS SPOKE. Prefers a sub-plan over
# its master when the sub is the in-progress one (most-specific active scope). Returns
# the first match; if multiple in-progress plans exist in the spoke, SessionStart stays
# silent (the UPS disambiguation slot handles the ambiguous case on the next prompt).
discover_in_progress() {
  local hits=0 found="" plan_dir sp_dir st master_proj proj
  for plan_dir in "$PLANS_DIR"/[0-9]*-*; do
    [[ -d "$plan_dir" ]] || continue
    master_proj=$(manifest_project "$plan_dir/manifest.json")
    # sub-plan dirs first (most specific)
    for sp_dir in "$plan_dir"/[0-9]*-* "$plan_dir"/SP-[0-9]*-*; do
      [[ -d "$sp_dir" ]] || continue
      st=$(manifest_status "$sp_dir/manifest.json")
      if [[ "$st" == "in-progress" ]]; then
        proj=$(manifest_project "$sp_dir/manifest.json")
        [[ -n "$proj" ]] || proj="$master_proj"
        if spoke_matches_project "$proj"; then
          hits=$((hits + 1)); found=".claude-plans/$(basename "$plan_dir")/$(basename "$sp_dir")"
        fi
      fi
    done
    st=$(manifest_status "$plan_dir/manifest.json")
    if [[ "$st" == "in-progress" ]] && spoke_matches_project "$master_proj"; then
      hits=$((hits + 1)); found=".claude-plans/$(basename "$plan_dir")"
    fi
  done
  # exactly one in-progress target -> anchor it; else stay silent (ambiguous/none)
  if [[ "$hits" -eq 1 ]]; then printf '%s' "$found"; fi
}

# Pointer-first on BOTH events: this spoke's armed chain wins; the per-event
# heuristics below fire only when the chain does not resolve (unarmed).
ARMED_REL=""
if command -v resolve_active_target_for_spoke >/dev/null 2>&1; then
  ARMED_REL=$(resolve_active_target_for_spoke "$PLANS_DIR" "$SPOKE")
fi
if [[ "$EVENT" == "UserPromptSubmit" ]]; then
  [[ -z "$PROMPT" ]] && exit 0
  PLAN_REL="$ARMED_REL"
  if [[ -z "$PLAN_REL" ]]; then
    PLAN_REL=$(resolve_from_prompt)
    # A prompt-referenced plan is this session's active plan only when this spoke owns it.
    if [[ -n "$PLAN_REL" ]] && ! spoke_owns_target "$PLAN_REL"; then PLAN_REL=""; fi
  fi
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
