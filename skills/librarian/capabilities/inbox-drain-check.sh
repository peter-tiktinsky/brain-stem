#!/bin/bash
# inbox-drain-check — Block session-close while a flat inbox note the session captured
# is still undecided, and persist the open undecided count for the SessionStart reader.
#
# Enforcement layer for the capture-is-decided rule (a captured note is born with its
# disposition; see promote-from-inbox.sh --capture). Companion to handoff-disposition-check:
# the same blocking-finding and exit-1 contract, run beside it in the session-close
# integrity step.
#
# Usage:
#   inbox-drain-check.sh --session-id <id> [--files <path> ...] [--dry-run]
#   inbox-drain-check.sh --help
#
# ATTRIBUTION. A flat note under <plans-root>/_inbox/ belongs to the session when its
# `captured_session:` equals --session-id, or its path is among the --files (the session's
# touched files; a path outside _inbox/ is ignored). Settled notes, _index.md, notes whose
# type is not idea and notes already carrying a `resolution:` are never read.
#
# DECIDED. A note is decided only in the three capture shapes:
#   STANDALONE  release_class in inbox.note_frontmatter.release_class_enum and size in
#               size_enum (plans pillar)
#   ABSORB      absorbed_into names a plan key (an optional ' :: T-N' suffix stripped)
#               whose manifest.json exists under the plans root
#   NO-BUILD    reopen_gate is an id hooks/lib/reopen-gate.sh --list names
# Anything else is undecided: a blank disposition, FIX NOW, an out-of-enum value, or one of
# the three missing what makes it real.
#
# FINDINGS. One blocking 'inbox-undecided-capture' per attributed undecided note (file,
# inbox_slug, disposition, reason, level error). Exit codes: 0 clean, 1 undecided captures
# exist, 2 a usage error or a failed scan (fail-closed).
# --dry-run changes only the manifest write below, never the findings or the exit.
#
# DURABLE LEAF. On every non-dry run (a zero count included, so a clean refresh silences the
# reader) the capability writes drift_findings.inbox_drain to the librarian manifest through
# manifest_set: last_scan, session_id, findings_count, open_entries (the attributed undecided
# slugs), undecided_total (every open undecided flat note, any session) and threshold
# (inbox.undecided_threshold, default 10). hooks/session-start-placement-findings.sh surfaces
# the leaf at the next SessionStart. Fail-open: without manifest_set or a resolvable state
# root the leaf is skipped, never the check.
#
# Env overrides: PLANS_ROOT (else PLANS_DIR), PLANS_RULES_PATH, FINDINGS_OUTPUT.
# Bash 3.2 clean per R-23. Argv-based Python per R-24.

set -u
set -o pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${PLANS_DIR:-}" && -z "${PLANS_ROOT:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh"; } \
  || { [ -r "$_REPO_LIB/manifest.sh" ] && source "$_REPO_LIB/manifest.sh"; } || true

SESSION_ID=""
FILES=""
DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --files)      FILES="${FILES}${2:-}"$'\n'; shift 2 ;;
    --dry-run)    DRY_RUN="true"; shift ;;
    -h|--help)    awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "inbox-drain-check: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

PLANS_ROOT_RES="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT_RES" in */) PLANS_ROOT_RES="${PLANS_ROOT_RES%/}" ;; esac

# The registered re-open gate ids, one per line (the reader is found sibling-first, then in
# the install root; an unreadable registry leaves the list empty, so a NO-BUILD note is
# undecided rather than silently decided).
GATES=""
for _rg in "$_REPO_LIB/reopen-gate.sh" "$CLAUDE_HOME_RES/hooks/lib/reopen-gate.sh"; do
  if [[ -f "$_rg" ]]; then
    GATES="$(bash "$_rg" --list 2>/dev/null)" || GATES=""
    break
  fi
done

# plans-rules.json: PLANS_RULES_PATH, else the install's loose pillar, else the foundation
# copy beside this script, else the merged view of the master bundles. Missing everywhere
# falls back to the pillar defaults inside the Python core.
RULES_PATH="${PLANS_RULES_PATH:-}"
if [[ -z "$RULES_PATH" || ! -f "$RULES_PATH" ]]; then
  RULES_PATH=""
  for _cand in "$CLAUDE_HOME_RES/governance/plans-rules.json" "$_REPO_ROOT/governance/plans-rules.json"; do
    if [[ -f "$_cand" ]]; then RULES_PATH="$_cand"; break; fi
  done
fi
_RULES_TMP=""
if [[ -z "$RULES_PATH" ]]; then
  for _loader in "$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh" "$_REPO_LIB/foundation-overlay-load.sh"; do
    [[ -x "$_loader" ]] || continue
    _RULES_TMP="$(mktemp 2>/dev/null)" || break
    if bash "$_loader" --query '.plans' --force-override > "$_RULES_TMP" 2>/dev/null \
         && [[ -s "$_RULES_TMP" ]] && [[ "$(head -c4 "$_RULES_TMP" 2>/dev/null)" != null ]]; then
      RULES_PATH="$_RULES_TMP"; break
    fi
    rm -f "$_RULES_TMP"; _RULES_TMP=""
  done
fi

SUMMARY_OUT="$(mktemp -t inbox-drain-summary-XXXXXX)"
trap 'rm -f "$SUMMARY_OUT" ${_RULES_TMP:+"$_RULES_TMP"}' EXIT

RESULT="$(python3 - "$PLANS_ROOT_RES" "$SESSION_ID" "$FILES" "$GATES" "$RULES_PATH" "$SUMMARY_OUT" <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

plans_root, session_id, files_raw, gates_raw, rules_path, summary_out = sys.argv[1:7]
inbox = os.path.join(plans_root, "_inbox")
gates = set(g.strip() for g in gates_raw.split("\n") if g.strip())

classes = ["local-release", "public-release", "post-release", "docs"]
sizes = ["day", "build"]
threshold = 10
try:
    with open(rules_path, encoding="utf-8") as fh:
        ib = json.load(fh).get("inbox", {})
    nf = ib.get("note_frontmatter", {})
    classes = nf.get("release_class_enum", classes)
    sizes = nf.get("size_enum", sizes)
    t = ib.get("undecided_threshold", threshold)
    if isinstance(t, int) and not isinstance(t, bool) and t >= 0:
        threshold = t
except (OSError, ValueError, AttributeError):
    pass

touched = set()
for p in files_raw.split("\n"):
    p = p.strip()
    if p:
        touched.add(os.path.realpath(p))


def frontmatter(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            return fm
        m = re.match(r"^([A-Za-z0-9_-]+):[ \t]*(.*)$", line)
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            fm[m.group(1)] = v
    return None


def why_undecided(fm):
    d = fm.get("disposition", "")
    if d == "STANDALONE":
        if fm.get("release_class", "") not in classes:
            return "STANDALONE without a release_class from the pillar enum"
        if fm.get("size", "") not in sizes:
            return "STANDALONE without a size from the pillar enum"
        return ""
    if d == "ABSORB":
        key = re.split(r"\s*::\s*", fm.get("absorbed_into", ""), 1)[0].strip()
        if (key and ".." not in key and not key.startswith("/")
                and os.path.isfile(os.path.join(plans_root, key, "manifest.json"))):
            return ""
        return "ABSORB without a resolvable absorbed_into plan key"
    if d == "NO-BUILD":
        if fm.get("reopen_gate", "") in gates:
            return ""
        return "NO-BUILD without a registered reopen_gate"
    if not d:
        return "no disposition"
    return "disposition '%s' is not a decided capture shape" % d


attributed = []
total = 0
try:
    entries = sorted(os.listdir(inbox))
except OSError:
    entries = []
for entry in entries:
    if not entry.endswith(".md") or entry.startswith("_") or entry.startswith("."):
        continue
    path = os.path.join(inbox, entry)
    if not os.path.isfile(path):
        continue
    fm = frontmatter(path)
    if fm is None or fm.get("type", "") != "idea" or fm.get("resolution", ""):
        continue
    reason = why_undecided(fm)
    if not reason:
        continue
    total += 1
    mine = (session_id and fm.get("captured_session", "") == session_id) \
        or os.path.realpath(path) in touched
    if mine:
        attributed.append((entry, fm.get("disposition", ""), reason))

for entry, disp, reason in attributed:
    print("%s\t%s\t%s" % (entry, disp, reason))

summary = {
    "last_scan": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "session_id": session_id,
    "findings_count": len(attributed),
    "open_entries": [e[:-3] for e, _, _ in attributed],
    "undecided_total": total,
    "threshold": threshold,
}
with open(summary_out, "w", encoding="utf-8") as fh:
    json.dump(summary, fh)
PY
)" || PY_RC=$?

# A crashed scan is not "nothing undecided": fail closed, never a silent pass of the gate.
if [[ "${PY_RC:-0}" -ne 0 ]]; then
  echo "inbox-drain-check: scan failed (python3 rc ${PY_RC}); undecided captures could not be checked" >&2
  exit 2
fi

COUNT=0
REPORT=""
while IFS=$'\t' read -r entry disp reason; do
  [[ -z "$entry" ]] && continue
  COUNT=$((COUNT + 1))
  slug="${entry%.md}"
  emit_finding "inbox-undecided-capture" "_inbox/$entry" \
    "inbox_slug" "$slug" \
    "disposition" "$disp" \
    "reason" "$reason" \
    "level" "error"
  REPORT="${REPORT}- _inbox/${entry} — ${reason}"$'\n'
done <<< "$RESULT"

# Persist the durable leaf on every non-dry run; fail-open.
if [[ "$DRY_RUN" != "true" && -s "$SUMMARY_OUT" ]] \
   && command -v manifest_set >/dev/null 2>&1 \
   && [[ -n "${CLAUDE_STATE_ROOT:-}" && -n "${COORD_DIR:-}" ]]; then
  manifest_set '.drift_findings.inbox_drain' "$(cat "$SUMMARY_OUT")" || true
fi

printf "## Inbox Drain (%d undecided)\n\n" "$COUNT"
if [[ -n "$REPORT" ]]; then
  printf '%s' "$REPORT"
else
  echo "- No undecided capture attributed to this session."
fi

[[ "$COUNT" -gt 0 ]] && exit 1
exit 0
