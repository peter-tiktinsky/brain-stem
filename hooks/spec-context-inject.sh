#!/bin/bash
# Hook: spec-context-inject — Inject the active plan's spec authority as context.
#
# PRIMARY firing: SessionStart (+ source:compact). The goal-anchor lands from turn 1
# and re-fires after compaction (fixing post-compaction instruction loss). The
# UserPromptSubmit slot is RETAINED for picking up a mid-session arming only (the
# pointer chain resolves fresh each prompt; the sentinel dedupes repeats). This body
# handles plan-execution context, not session orchestration.
#
# LAUNCH-SPOKE KEYED. The plan injected is the one armed in THIS session's launch
# spoke and no other. The payload `.cwd` is resolved to a spoke key through the shared
# cwd->spoke resolver (skills/new-plan/lib/spoke-resolve.sh — the same resolver the
# situating card keys on), and the arm pointer is read for that spoke
# (hooks/lib/active-plan-resolve.sh). A plan armed for another spoke is never injected
# here, and the one unarmed fallback below (SessionStart discovery) is scoped to the
# same spoke. A launch dir under no registered anchor is the `home` catch-all, which
# reads the plan corpus unfiltered — a single-spoke install sees no behaviour change.
#
# Behavior: master/sub plans are first-class; the canonical status vocabulary gates
# firing; agent-reload names the non-superseded decision_records[].
#
# Trigger: keys on the manifest `status` (re-points off the retired top_level_status).
# Armed, on both events: an armed plan is injected only while its status is in-progress.
# Unarmed, SessionStart: discovery anchors a plan only when it is the single in-progress
# plan of the spoke. Unarmed, UserPromptSubmit: an unarmed prompt injects nothing, whatever
# plan the prompt names, because the prompt text can carry injected content (a scheduled
# task, a background subagent report, a message another session sends) as well as the
# human's own words.
#
# Pointer payload (every plan type): the banner, the spec path, the current task id and
# title, the non-superseded ADR ids and titles, the master id for a sub-plan, and the
# `plan-context <slug>` command that prints any slice (task, section, canonical research,
# decisions, handoff). No spec or manifest body is inlined.
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

# A compaction drops the context the spec-inflection pointer supplied, so SessionStart
# source=compact clears this session's inflection sentinels (written by
# hooks/pre-write-guard.sh under $HOOKS_STATE/spec-inflection/) and the next plan write
# carries the pointer again. Any other source clears nothing. Runs before every exit
# below, so it holds whether or not a plan resolves.
if [[ "$SOURCE" == "compact" && -z "$PROMPT" ]]; then
  _infl_state="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-}}"
  if [[ -n "$_infl_state" && -d "$_infl_state/spec-inflection" ]]; then
    _infl_key="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '_')--"
    for _infl_f in "$_infl_state/spec-inflection/$_infl_key"*.flag; do
      [[ -f "$_infl_f" ]] && rm -f "$_infl_f" 2>/dev/null || true
    done
  fi
  unset _infl_state _infl_key _infl_f
fi

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
# the spoke-scoped SessionStart discovery below carries the hook.
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
# when it resolves, it wins. One heuristic survives, ONLY as the unarmed fallback, scoped
# to the same spoke:
#   SessionStart:     discover the single in-progress plan OF THIS SPOKE (goal-anchor).
#   UserPromptSubmit: no unarmed fallback — several in-progress plans in the spoke leave
#                     SessionStart silent, and a later prompt does not resolve them.
# The prompt is never read for a plan: a plan merely NAMED there must never be injected
# as "the active plan" (the wrong-framing vector: bystander plan Y's spec labeled
# authoritative while armed mid-build on X, or on text that another session sent). A plan
# belonging to ANOTHER spoke is not this session's active plan at all. For the `home`
# catch-all every leg reads the corpus unfiltered.

PLAN_REL=""   # path relative to $HOME, e.g. .claude-plans/93-foo OR .claude-plans/93-foo/-bar

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

# Discover the single in-progress plan target OF THIS SPOKE. Prefers a sub-plan over
# its master when the sub is the in-progress one (most-specific active scope). Returns
# the first match; if multiple in-progress plans exist in the spoke, SessionStart stays
# silent (several in-progress plans in the spoke leave it no single plan to anchor).
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

# Pointer-first on BOTH events: this spoke's armed chain wins. Unarmed, only SessionStart
# discovery below resolves a plan; an unarmed UserPromptSubmit exits here, silent.
ARMED_REL=""
if command -v resolve_active_target_for_spoke >/dev/null 2>&1; then
  ARMED_REL=$(resolve_active_target_for_spoke "$PLANS_DIR" "$SPOKE")
fi
if [[ "$EVENT" == "UserPromptSubmit" ]]; then
  [[ -z "$PROMPT" ]] && exit 0
  PLAN_REL="$ARMED_REL"
  [[ -z "$PLAN_REL" ]] && exit 0
else
  # SessionStart (+ source:compact, resume, startup)
  PLAN_REL="$ARMED_REL"
  [[ -z "$PLAN_REL" ]] && PLAN_REL=$(discover_in_progress)
  [[ -z "$PLAN_REL" ]] && exit 0
fi

TARGET_ABS="$PLANS_DIR/${PLAN_REL#.claude-plans/}"
[[ -d "$TARGET_ABS" ]] || exit 0
[[ -f "$TARGET_ABS/spec.md" ]] || exit 0

TARGET_MANIFEST="$TARGET_ABS/manifest.json"

# Status gate keyed on the canonical 6-state vocabulary: only an in-progress plan gets
# active-context injection. Every other status exits silent: planned, paused, completed,
# superseded, and the empty status an unreadable manifest yields. The hook reads
# `.status` (NOT the retired top_level_status alias).
TARGET_STATUS=$(manifest_status "$TARGET_MANIFEST")
case "$TARGET_STATUS" in
  in-progress) ;;
  *) exit 0 ;;
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

# Context build — FACTUAL framing, pointers only. No spec body, manifest projection or
# master spec is inlined: `plan-context` prints any slice on demand, so the payload stays
# a few hundred bytes whatever the size of the spec.
# The current task: the first tasks[] entry whose status front token is not done or cut
# (the predicate the pre-write-guard spec inflection arm uses).
CUR_TASK=""
if [[ -f "$TARGET_MANIFEST" ]]; then
  CUR_TASK=$(jq -r '[.tasks[]? | select(((.status // "") | tostring | split(" (")[0] | ascii_downcase | gsub("_"; "-")) as $s | ($s != "done" and $s != "cut"))][0] | if . then "\(.id // "")\t\(.title // "")" else "" end' "$TARGET_MANIFEST" 2>/dev/null || true)
fi
CUR_TID="${CUR_TASK%%$'\t'*}"
CUR_TTITLE="${CUR_TASK#*$'\t'}"

# Non-superseded ADRs (id and title) via manifest.decision_records[]; superseded and
# deprecated entries are left out. Graceful no-op when absent or empty.
ADR_LINES=""
if [[ -f "$TARGET_MANIFEST" ]]; then
  ADR_LINES=$(jq -r '
    (.decision_records // [])
    | map(select((.status // "") != "superseded" and (.status // "") != "deprecated"))
    | .[]? | "- \(.id): \(.title)"
  ' "$TARGET_MANIFEST" 2>/dev/null || true)
fi

context="## SPEC AUTHORITY — active plan: \`$PLAN_REL\` ($PLAN_TYPE)

The authoritative spec for the active plan is \`$PLAN_REL/spec.md\`. The spec ranks above any operational brief; if a brief and the spec disagree, the spec is authoritative and the brief is treated as defective. Framing claims should be grounded in spec text (cite line numbers in close-out summaries).
"
if [[ "$PLAN_TYPE" == "sub" && -n "$MASTER_SLUG" ]]; then
  context+="
Master plan: \`$MASTER_SLUG\` (this plan is one of its sub-plans)."
fi
if [[ -n "$CUR_TID" ]]; then
  context+="
Current task: $CUR_TID — $CUR_TTITLE"
else
  context+="
Current task: none open in \`manifest.json\`."
fi
if [[ -n "$ADR_LINES" ]]; then
  context+="

Active decision records (non-superseded):
$ADR_LINES"
fi
if [[ -n "$CUR_TID" ]]; then
  context+="

\`plan-context $PLAN_SLUG --task $CUR_TID\` prints the current task's slice. \`plan-context $PLAN_SLUG\` prints the plan map; its --section, --canon, --decisions and --handoff selectors print one slice each."
else
  context+="

\`plan-context $PLAN_SLUG\` prints the plan map; its --task, --section, --canon, --decisions and --handoff selectors print one slice each."
fi

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
