#!/bin/bash
# plan-terminal-lag-check — Close-time surface-and-walk enforcement for the
# plan-terminal-lag class: a plan whose own status is NON-terminal under a
# parent_plan master whose status IS terminal.
# Landed: sub 09 (G-LIFECYCLE) T-1 (2026-07-03). Closes WF-A//
# (wfA-brain-stem-fix-catalog.md:98-100) via the DT-3 SURFACE-AND-WALK model
# (151-158)./RESOLVED at (manifest decision_records).
# SEMANTICS (child-up view — the INVERSE of plan-archive.sh's master-DOWN
# subtree gate): for each plan dir under PLANS_ROOT whose manifest carries
# `parent_plan`, resolve the parent master's manifest status; if
#   master.status ∈ TERMINAL  AND  plan.status ∉ TERMINAL
# emit a `plan-terminal-lag` finding (fields: plan_slug, plan_status, parent_plan,
# parent_status, level) and PROMPT the walk in the report text. This is
# SURFACE-AND-WALK, NOT auto-close: the cap WRITES NO manifest status anywhere,
# never auto-stamps `verified` (the dogfood-harness machine-gate is
# preserved: verified is stamped ONLY by the harness verdict seam), and touches
# NO aggregation (first-match precedence UNCHANGED). Downward auto-propagation
# of a master's terminal status DOWN to subs is REJECTED (the +1 rejected option in
# DT-3/— it risks falsely closing genuine WIP).
# TERMINAL = {"verified","closed","archived","superseded"} — the canonical set,
# BYTE-IDENTICAL to plan-archive.sh:148 / trinity-drift-detect.sh:83 /
# subplan-aggregate.sh:134 (T-2's ac-terminal-set-parity.sh parity-gates all 4).
# `completed` is NOT terminal (completed->verified is the machine gate per
# schemas/plan-manifest-schema.json status.enum), so a `completed` master does NOT
# trigger the lag — CORRECT and SoT-consistent.
# Output Contract
#   Files written: NONE (surface-and-walk). Findings to stdout (NDJSON via
#     hooks/lib/findings.sh) or $FINDINGS_OUTPUT. Reads plan+master manifests
#     read-only; never mutates a manifest.
#   Failure mode: block-and-log; never write-and-hope. A manifest that fails the
#     minimal validity guard is skipped (not emitted-against).
# Finding category:
#   plan-terminal-lag  (plan_slug, plan_status, parent_plan, parent_status, level)
# CLI:
#   plan-terminal-lag-check.sh            # sweep all plans under PLANS_ROOT
#   plan-terminal-lag-check.sh --help
# Env overrides:
#   PLANS_ROOT / PLANS_DIR   plan-tree root (test isolation)
#   PLAN_MANIFEST_SCHEMA     plan-manifest-schema.json (default: foundation -> live)
#   FINDINGS_OUTPUT          NDJSON sink (default: stdout)
#   FOUNDATION_TEST_MODE     bypass the non-interactive guard
# Exit: 0 no lag found; 1 one or more lag findings; 2 setup error. (The
#   session-close run_capability wrapper always returns 0 and records the cap as
#   `error` in the chain log on a non-zero exit — so the cap exits non-zero on
#   findings [mirroring handoff-disposition-check] AND session-close stays
#   advisory [exit 0], at different layers.)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"
if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "plan-terminal-lag-check: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
if [[ ! -d "$PLANS_ROOT" ]]; then
  echo "plan-terminal-lag-check: PLANS_ROOT does not exist: $PLANS_ROOT" >&2
  exit 2
fi

SCHEMA_PATH="${PLAN_MANIFEST_SCHEMA:-}"
if [[ -z "$SCHEMA_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RES/schemas/plan-manifest-schema.json"; do
    if [[ -f "$candidate" ]]; then SCHEMA_PATH="$candidate"; break; fi
  done
fi

python3 - "$PLANS_ROOT" "$SCHEMA_PATH" <<'PY'
import json, os, sys

plans_root = sys.argv[1]
schema_path = sys.argv[2]

TERMINAL = {"verified", "closed", "archived", "superseded"}

validator = None
if schema_path and os.path.isfile(schema_path):
    try:
        import jsonschema  # type: ignore
        with open(schema_path, encoding="utf-8") as fh:
            _schema = json.load(fh)
        validator = jsonschema.Draft202012Validator(_schema)
    except Exception:
        validator = None

def manifest_valid(m):
    for req in ("schema_version", "project", "spec_path"):
        if req not in m:
            return False
    if validator is not None:
        try:
            validator.validate(m)
        except Exception:
            return False
    return True

def emit(d):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(d, separators=(", ", ": "), sort_keys=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        print(line)

def load_manifest(slug):
    path = os.path.join(plans_root, slug, "manifest.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            m = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None
    return m if isinstance(m, dict) else None

# Candidate walk over the plan-tree dirs (same shape as plan-archive.sh:249-254 /
# subplan-aggregate / trinity-drift-detect): skip dot/underscore dirs + Logs.
candidates = sorted(e for e in os.listdir(plans_root)
                    if not e.startswith(".") and not e.startswith("_")
                    and os.path.isdir(os.path.join(plans_root, e)) and e != "Logs")

# Cache master statuses so a shared parent is resolved once.
master_status_cache = {}
def parent_status(parent_slug):
    if parent_slug in master_status_cache:
        return master_status_cache[parent_slug]
    pm = load_manifest(parent_slug)
    st = ""
    if pm is not None and manifest_valid(pm):
        st = str(pm.get("status", "")).strip()
    master_status_cache[parent_slug] = st
    return st

lag_count = 0
for slug in candidates:
    m = load_manifest(slug)
    if m is None or not manifest_valid(m):
        continue
    parent = str(m.get("parent_plan", "")).strip()
    if not parent:
        continue
    # A plan with NO status key is tolerated (no crash): "" ∉ TERMINAL, but the
    # spec's lag test is a NON-terminal-under-terminal surfacing — a status-less
    # plan carries no asserted status to walk, so it does NOT surface a lag.
    plan_status = str(m.get("status", "")).strip()
    if not plan_status:
        continue
    if plan_status in TERMINAL:
        continue
    p_status = parent_status(parent)
    if p_status not in TERMINAL:
        continue
    # child-up lag: non-terminal plan under a terminal master.
    lag_count += 1
    emit({"finding": "plan-terminal-lag", "file": slug,
          "plan_slug": slug, "plan_status": plan_status,
          "parent_plan": parent, "parent_status": p_status,
          "level": "warn"})

# Report text (stdout) — surface-and-walk: PROMPT the walk explicitly.
if lag_count > 0:
    sys.stderr.write(
        "## Plan-terminal-lag (%d)\n\n"
        "%d plan(s) are non-terminal under a TERMINAL parent_plan master.\n"
        "SURFACE-AND-WALK: this does NOT auto-close. WALK each surfaced plan to a\n"
        "terminal status (verified via the dogfood harness, or closed/archived/\n"
        "superseded by hand) or confirm it is genuine WIP.\n" % (lag_count, lag_count))
else:
    sys.stderr.write("## Plan-terminal-lag (0)\n\n- No non-terminal plans under a terminal master. Nothing to walk.\n")

sys.exit(1 if lag_count > 0 else 0)
PY
