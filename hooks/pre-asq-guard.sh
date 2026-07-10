#!/bin/bash
# Hook: PreToolUse (AskUserQuestion) — Session-decision-guard for option-shape
# decisions. Matcher-split discipline:
# AskUserQuestion lives here; Edit|Write lives in pre-write-guard.sh.
# Branches (modular composition per — each branch is an independent
# function that emits a text fragment or empty; composer concatenates):
#   decision_quality_branch()   — advisory + telemetry/
#                                 annotation grammar + Phase 1/2 env-var-flip.
#                                 Ported from live pre-write-guard.sh:40-184
#                                 per T-2 (port-first discipline).
#   hard_constraints_branch()   — Hard-Constraints-Override-Spec reminder
#                                 (branch #5). Fires when substantive
#                                 option set is detected.
#   compose_additional_context() — concatenates non-empty fragments into a
#                                  single additionalContext payload.
# Phase 2 deny takes priority over fragment composition: when
# decision_quality_branch() flips to deny under PRE_ASQ_GUARD_DQ_PHASE=2-blocking
# (alias PRE_WRITE_GUARD_DQ_PHASE preserved for back-compat), the hook emits
# format_output_deny with the DQP reason; HC fragment is appended for
# transparency.
set -euo pipefail

# hardcoded install-path literal ([DRIFT] 3; AC).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/registry.sh"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Matcher-split guard: only act on AskUserQuestion. Other matchers shouldn't
# reach this hook per settings.json, but guard defensively in case the matcher
# config is mis-wired during install or fixture setup (T-18).
if [[ "$TOOL_NAME" != "AskUserQuestion" ]]; then
  exit 0
fi

# === Branch output state (set by branch functions) ========================
DQP_DECISION="allow"   # allow | deny
DQP_FRAGMENT=""
HC_FRAGMENT=""

# === decision_quality_branch() ============================================
# PORTED from live ~/.claude/hooks/pre-write-guard.sh:40-184 per T-2
# (port-first discipline). Preserves+:
#   - Substantive-shape heuristic (option count ≥ 2 + description > 50 chars
#     OR keyword match in question text)
#   - Skip-conditions (yes/no canonical labels; no signals)
#   - annotation grammar (`\bresearch_complete:\s*\S+`)
#   - Phase 1 (1-advisory): substantive + no annotation → nudge
#   - Phase 2 (2-blocking): substantive + no annotation → deny
#   - JSONL telemetry row per fire to $DQ_EVENTS_PATH (fixture-overridable)
# Sets DQP_DECISION ∈ {allow, deny} + DQP_FRAGMENT (text or empty).
decision_quality_branch() {
  local aq_input_file aq_telemetry_path aq_phase aq_decision aq_session_id
  aq_input_file=$(mktemp "${TMPDIR:-/tmp}/sp01-aq-input.XXXXXX")
  printf '%s' "$INPUT" > "$aq_input_file"
  # Telemetry path overridable via $DQ_EVENTS_PATH for fixture isolation.
  aq_telemetry_path="${DQ_EVENTS_PATH:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/runtime/decision-quality-events.jsonl}"
  mkdir -p "$(dirname "$aq_telemetry_path")" 2>/dev/null || true
  # Phase: 2-blocking (default) or 1-advisory (env-override). Operator RATIFIED
  # the Phase-2 promotion 2026-07-07 (52-row gate cleared: 45 allow-annotated /
  # 7 nudge, all 7 desclen-non-yesno); the live env flip is already applied and
  # this makes the foundation default follow. PRE_ASQ_GUARD_DQ_PHASE is the new
  # canonical name; PRE_WRITE_GUARD_DQ_PHASE preserved as back-compat alias since
  # live operators may have it set.
  aq_phase="${PRE_ASQ_GUARD_DQ_PHASE:-${PRE_WRITE_GUARD_DQ_PHASE:-2-blocking}}"
  # session_id: env preferred, stdin `.session_id` fallback (mirrors
  # pre-compact-checkpoint.sh:46-49), then "unknown". CLAUDE_SESSION_ID is NOT
  # exported into PreToolUse hooks, so without the stdin fallback every telemetry
  # row carried session_id='unknown' — the fallback reads the id from the already
  # captured $INPUT payload.
  aq_session_id="${CLAUDE_SESSION_ID:-}"
  if [[ -z "$aq_session_id" ]]; then
    aq_session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  fi
  [[ -z "$aq_session_id" ]] && aq_session_id="unknown"
  # NOTE: pass file-path via argv (NOT stdin). python3 - <<EOF consumes the
  # heredoc as stdin, so a piped JSON would be silently ignored
  # (feedback_python_heredoc_argv.md). The heredoc IS the script source;
  # data flows in through argv[1..4].
  aq_decision=$(python3 - "$aq_input_file" "$aq_telemetry_path" "$aq_phase" "$aq_session_id" <<'PYEOF' 2>/dev/null || echo "allow"
import sys, json, re, datetime, os
KEYWORDS = re.compile(r'\b(approach|option|(?:which|code|execution|happy|critical|decision) path|strategy|direction|which way|should we)\b', re.I)
YESNO = re.compile(r'^(yes|yeah|yep|sure|ok|okay|no|nope|cancel|skip|continue|stop|done|abort|allow|deny)\b', re.I)
ANNOTATION = re.compile(r'\bresearch_complete:\s*\S+', re.I)
input_path, telemetry_path, phase, session_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(input_path) as f:
        data = json.load(f)
except Exception:
    print("allow"); sys.exit(0)
questions = data.get('tool_input', {}).get('questions', []) or []
substantive = False
keyword_matched = False
description_length_signal = False
yesno_shape = False
options_count_total = 0
annotation_present = False
for q in questions:
    if not isinstance(q, dict):
        continue
    qtext = q.get('question', '') or ''
    options = q.get('options', []) or []
    options_count_total += len(options)
    # annotation in question text
    if ANNOTATION.search(qtext):
        annotation_present = True
    # annotation in option labels/descriptions
    for o in options:
        if not isinstance(o, dict):
            continue
        if ANNOTATION.search((o.get('label', '') or '')) or ANNOTATION.search((o.get('description', '') or '')):
            annotation_present = True
    # substantive-shape detection (heuristic)
    if substantive:
        continue
    if KEYWORDS.search(qtext):
        substantive = True
        keyword_matched = True
        continue
    if len(options) < 2:
        continue
    if len(options) == 2:
        labels = [(o.get('label', '') or '').strip() for o in options if isinstance(o, dict)]
        if len(labels) == 2 and all(YESNO.match(L) for L in labels):
            yesno_shape = True
            continue
    if any(len((o.get('description', '') or '')) > 50 for o in options if isinstance(o, dict)):
        substantive = True
        description_length_signal = True
# Decide emission.
# Phase 1 (1-advisory): substantive + no annotation → nudge; else allow (silent or annotated)
# Phase 2 (2-blocking): substantive + no annotation → deny; substantive + annotation → allow-annotated; else allow
if substantive and not annotation_present:
    decision = "deny" if phase == "2-blocking" else "nudge"
elif substantive and annotation_present:
    decision = "allow-annotated"
else:
    decision = "allow"
# Append telemetry row.
row = {
    "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "session_id": session_id,
    "phase": phase,
    "questions_count": len(questions),
    "options_count": options_count_total,
    "substantive_shape_detected": substantive,
    "keyword_matched": keyword_matched,
    "description_length_signal": description_length_signal,
    "yesno_shape": yesno_shape,
    "annotation_present": annotation_present,
    "decision": decision,
}
try:
    with open(telemetry_path, 'a') as f:
        f.write(json.dumps(row, separators=(',', ':')) + "\n")
except Exception:
    pass
print(decision)
PYEOF
)
  rm -f "$aq_input_file"

  case "$aq_decision" in
    nudge)
      DQP_FRAGMENT="[Decision-Quality Protocol —/] You are presenting a substantive option set. Run the 4-element research pass BEFORE publishing:

1. Project goals — re-read the active plan's spec, manifest, recent handoff.
2. Inter-project deps — check adjacent plans (predecessor, in-flight, coordinate-with) for conflicts/synergies.
3. Live-vault state — read current files; do not trust memory.
4. +1 unconsidered option — generate one option NOT yet on the table; expand the option space.

Then re-rank, recommend, and surface trade-offs. After running the pass, re-issue this AskUserQuestion with \`research_complete: <one-line summary>\` prefixed to the question text (or embedded in an option description). The annotation marks this call as protocol-compliant. Empirically, the user overrides the first-presented option ≈100% of the time without this pass. Source: ~/.claude/CLAUDE.md § Decision-Quality Protocol."
      DQP_DECISION="allow"
      ;;
    deny)
      DQP_FRAGMENT="[Decision-Quality Protocol — Phase 2] This AskUserQuestion presents a substantive option set without a \`research_complete:\` annotation. Run the 4-element research pass (project goals, inter-project deps, live-vault state, +1 unconsidered option) and re-issue with \`research_complete: <one-line summary>\` prefixed to the question text or embedded in an option description. Source: ~/.claude/CLAUDE.md § Decision-Quality Protocol."
      DQP_DECISION="deny"
      ;;
    allow-annotated|allow|*)
      DQP_FRAGMENT=""
      DQP_DECISION="allow"
      ;;
  esac
}

# === hard_constraints_branch() ============================================
# Per +: emits Hard-Constraints-Override-Spec reminder when a
# substantive option set is detected. Replaces the rule formerly stated in
# the user's live global CLAUDE.md § "Hard Constraints Override Spec Text".
# Reuses the substantive-shape detection logic (replicated, not shared,
# per modular-independence principle). Fires regardless of annotation —
# the constraint check is orthogonal to research-completeness.
# Sets HC_FRAGMENT (text or empty). Never denies.
hard_constraints_branch() {
  local hc_input_file hc_substantive
  hc_input_file=$(mktemp "${TMPDIR:-/tmp}/hc-aq-input.XXXXXX")
  printf '%s' "$INPUT" > "$hc_input_file"
  hc_substantive=$(python3 - "$hc_input_file" <<'PYEOF' 2>/dev/null || echo "false"
import sys, json, re
KEYWORDS = re.compile(r'\b(approach|option|(?:which|code|execution|happy|critical|decision) path|strategy|direction|which way|should we)\b', re.I)
YESNO = re.compile(r'^(yes|yeah|yep|sure|ok|okay|no|nope|cancel|skip|continue|stop|done|abort|allow|deny)\b', re.I)
input_path = sys.argv[1]
try:
    with open(input_path) as f:
        data = json.load(f)
except Exception:
    print("false"); sys.exit(0)
questions = data.get('tool_input', {}).get('questions', []) or []
substantive = False
for q in questions:
    if not isinstance(q, dict):
        continue
    if substantive:
        break
    qtext = q.get('question', '') or ''
    options = q.get('options', []) or []
    if KEYWORDS.search(qtext):
        substantive = True
        continue
    if len(options) < 2:
        continue
    if len(options) == 2:
        labels = [(o.get('label', '') or '').strip() for o in options if isinstance(o, dict)]
        if len(labels) == 2 and all(YESNO.match(L) for L in labels):
            continue
    if any(len((o.get('description', '') or '')) > 50 for o in options if isinstance(o, dict)):
        substantive = True
print("true" if substantive else "false")
PYEOF
)
  rm -f "$hc_input_file"

  if [[ "$hc_substantive" == "true" ]]; then
    HC_FRAGMENT="[Hard Constraints Override Spec Text] When a stated constraint (no live mutations, no destructive ops without confirmation, etc.) conflicts with a spec, plan, or task description, the spec is treated as DEFECTIVE. Options that violate the constraint do NOT appear in option-comparison tables. The user does not get to 'choose between honoring or violating' their own rule — the constraint already settled the question. Flag the spec as defective and propose corrections. Source: ~/.claude/CLAUDE.md § Hard Constraints Override Spec Text."
  fi
}

# === compose_additional_context() =========================================
# Concatenates non-empty fragments with a blank-line separator. Returns the
# combined text on stdout (empty string if no fragments). Per: "Hook
# concatenates fragments into a single additionalContext and emits one
# allow decision."
compose_additional_context() {
  local combined=""
  if [[ -n "$DQP_FRAGMENT" ]]; then
    combined="$DQP_FRAGMENT"
  fi
  if [[ -n "$HC_FRAGMENT" ]]; then
    if [[ -n "$combined" ]]; then
      combined="${combined}

${HC_FRAGMENT}"
    else
      combined="$HC_FRAGMENT"
    fi
  fi
  printf '%s' "$combined"
}

# === Main =================================================================
decision_quality_branch
hard_constraints_branch

if [[ "$DQP_DECISION" == "deny" ]]; then
  # Phase 2 deny path. DQP reason is primary; HC fragment appended for
  # transparency (HC is informational, not blocking).
  reason="$DQP_FRAGMENT"
  if [[ -n "$HC_FRAGMENT" ]]; then
    reason="${reason}

${HC_FRAGMENT}"
  fi
  format_output_deny "PreToolUse" "$reason"
  exit 0
fi

ctx=$(compose_additional_context)
if [[ -n "$ctx" ]]; then
  format_output_allow "PreToolUse" "$ctx"
fi
exit 0
