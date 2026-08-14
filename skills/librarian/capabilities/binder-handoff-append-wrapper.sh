#!/bin/bash
# binder-handoff-append-wrapper — the thin session-close ADAPTOR that wires the
# shipped-but-ORPHANED hooks/handoff-chronicle-append.sh into the session-close
# capability chain.
#
# THE PROBLEM IT SOLVES: hooks/handoff-chronicle-append.sh is the SECONDARY-ROLE
# (incremental append) half of the composite maintainer for the per-spoke
# binder handoff-chronicle.md. It was designed for the session-close seam but takes
# POSITIONAL args (`<handoff.md path> <spoke> [<plan-slug>]`), so the generic
# session-close `run_capability` wrapper — which shifts the capability name and
# passes the REST as `--flag value` style args — cannot drive it directly. This
# adaptor accepts `--spoke <key>` (so `run_capability binder-handoff-append-wrapper
# --spoke "$active_spoke"` works), resolves the just-finalized handoff.md path for
# that spoke's active (in-progress) plan, and invokes the positional-arg appender.
#
# RESOLUTION (the just-finalized handoff.md for the active spoke): the active spoke
# is passed in (--spoke), resolved upstream by session-close from the session cwd.
# We walk PLANS_ROOT for the spoke's plans (a manifest.json whose `project:` key ==
# the spoke), prefer the IN-PROGRESS plan, and within it pick the most-recently-
# written handoff.md (mtime) — that is the just-finalized handoff for this close.
# If no in-progress plan is found, fall back to the most-recently-written handoff.md
# across ALL of the spoke's plans (the close that just ran most likely touched it).
#
# ORDERING (append-before-re-derive): session-close fires this adaptor BEFORE plan-handoff-index's full
# re-derive, so the appended block is absorbed idempotently by the re-derive (which
# owns the whole file and rebuilds the sentinel region from disk). The append +
# the re-derive are DISJOINT roles and render IDENTICAL block text, so
# running both produces NO duplication.
#
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT):
#   Files written:
#     - NONE directly. This adaptor performs NO file write of its own; it resolves
#       the active spoke's just-finalized handoff.md and delegates the single
#       sentinel-region append to hooks/handoff-chronicle-append.sh, which is the
#       sole writer (it appends ONE block at the HEAD of the chronicle's
#       sentinel-bounded region `<!-- handoff-chronicle:start --> … :end -->`,
#       atomic temp+os.replace). See that hook's Output Contract for the write
#       surface + the full-re-derive idempotency relationship.
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT) on block-and-log.
#   Schema: null (no JSON Schema governs this adaptor; the chronicle block shape is
#     fixed by in the delegated appender).
#   Pre-write validation:
#     - the spoke arg must be non-empty (else block-and-log, defensive skip, exit 0).
#     - a handoff.md must resolve for the spoke (else block-and-log defensive skip
#       finding, exit 0 — an unresolvable handoff/spoke NEVER crashes the close).
#     - the delegated appender re-validates (readable non-empty handoff, parseable
#       session block) and is itself block-and-log.
#   Failure mode: BLOCK-AND-LOG. Unresolvable spoke / no handoff.md / a delegated
#     appender failure all emit a finding and exit 0 (never crash the close).
#   Maintainer-provenance: this adaptor writes nothing itself; it is the
#     session-close DRIVER for the append-one-block secondary-role surface. It never
#     re-derives, never rewrites prior blocks, never touches the frontmatter/intro.
#
# CLI:
#   binder-handoff-append-wrapper.sh --spoke <key>
#   binder-handoff-append-wrapper.sh --spoke <key> --handoff <path>   # explicit override
#   binder-handoff-append-wrapper.sh --help
#
# Env overrides (testing / wiring):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh).
#   FINDINGS_OUTPUT         NDJSON sink for block-and-log findings (default: stdout).
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24 (data via argv, never
# piped stdin the heredoc would consume).

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
# capabilities/ -> skills/librarian -> skills -> repo root
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

SPOKE_ARG=""
HANDOFF_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spoke)   SPOKE_ARG="${2:-}"; shift 2 ;;
    --handoff) HANDOFF_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "binder-handoff-append-wrapper: unknown flag [$1]" >&2; exit 2 ;;
  esac
done

# --- plans home resolution (the sibling capability pattern; never hardcoded) ---
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

TODAY="$(date +%Y-%m-%d)"

emit_finding_line() {
  # block-and-log: one NDJSON finding line to $FINDINGS_OUTPUT or stdout.
  local line="$1"
  if [[ -n "${FINDINGS_OUTPUT:-}" ]]; then
    printf '%s\n' "$line" >> "$FINDINGS_OUTPUT"
  else
    printf '%s\n' "$line"
  fi
}

# --- block-and-log: empty spoke -> defensive skip, exit 0 (never crash close) ---
if [[ -z "$SPOKE_ARG" ]]; then
  emit_finding_line "{\"finding\": \"binder-handoff-append-wrapper-skipped\", \"reason\": \"empty-spoke\", \"detected_at\": \"$TODAY\"}"
  echo "binder-handoff-append-wrapper: empty --spoke; defensive skip (no append)" >&2
  exit 0
fi

# --- resolve the just-finalized handoff.md for the active spoke --------------
# Walk PLANS_ROOT for plans whose manifest.json `project:` == the spoke; prefer
# the in-progress plan; within it pick the most-recently-written handoff.md by
# mtime (the just-finalized handoff for this close). Fall back to the newest
# handoff.md across all the spoke's plans if no in-progress plan resolves.
#
# sweep verdict (T-3): the mtime tiebreak here is DELIBERATE, not
# the arm-pointer divergence class. This adaptor answers the SESSION-scoped
# question "which handoff did this close just finalize" — not "which plan is
# armed" — so pointer-first resolution would MISROUTE a close on a non-armed
# plan of the same spoke. Exposure of a wrong tiebreak is self-correcting within
# the same close: plan-handoff-index's full re-derive (fired immediately after
# in session-close) owns the chronicle and rebuilds it from every plan's handoff
# on disk.
if [[ -n "$HANDOFF_OVERRIDE" ]]; then
  HANDOFF_PATH="$HANDOFF_OVERRIDE"
else
  # Run the resolver BARE (never inside $(...) — a quoted heredoc inside command
  # substitution makes `bash -n` parse the heredoc body and choke on a literal
  # apostrophe; every sibling capability runs its heredoc bare). The resolved
  # handoff.md path is written to a temp file the resolver receives as argv[3],
  # then read back here.
  _RESOLVED="${TMPDIR:-/tmp}/binder-handoff-resolve-$$.path"
  : > "$_RESOLVED"
  python3 - "$PLANS_ROOT" "$SPOKE_ARG" "$_RESOLVED" <<'PY'
import json, os, sys

plans_root, spoke, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
projects_dir = os.path.join(plans_root, "_projects")


def write_result(path):
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(path or "")


if not os.path.isdir(plans_root):
    write_result("")  # plans home absent -> resolve nothing (caller block-and-logs the skip)
    sys.exit(0)


def read_json(p):
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


# collect (plan_dir, status, handoff_path, handoff_mtime) for each plan in the spoke.
candidates = []
for dp, dns, fns in os.walk(plans_root):
    dns[:] = [d for d in dns if not d.startswith(".")]
    # never descend into the binder home itself
    if os.path.abspath(dp) == os.path.abspath(projects_dir):
        dns[:] = []
        continue
    if "manifest.json" not in fns:
        continue
    man = read_json(os.path.join(dp, "manifest.json"))
    if man is None or not isinstance(man, dict):
        continue
    if str(man.get("project") or "").strip() != spoke:
        continue
    handoff = os.path.join(dp, "handoff.md")
    if not os.path.isfile(handoff):
        continue
    try:
        mtime = os.path.getmtime(handoff)
    except Exception:
        mtime = 0.0
    status = str(man.get("status") or "").strip()
    candidates.append((dp, status, handoff, mtime))

if not candidates:
    write_result("")
    sys.exit(0)

# prefer the in-progress plan; within the preferred set, newest handoff.md by mtime.
in_progress = [c for c in candidates if c[1] == "in-progress"]
pool = in_progress if in_progress else candidates
pool.sort(key=lambda c: c[3], reverse=True)
write_result(pool[0][2])
PY
  HANDOFF_PATH="$(cat "$_RESOLVED" 2>/dev/null)"
  rm -f "$_RESOLVED"
fi

if [[ -z "$HANDOFF_PATH" || ! -f "$HANDOFF_PATH" ]]; then
  emit_finding_line "{\"finding\": \"binder-handoff-append-wrapper-skipped\", \"spoke\": \"$SPOKE_ARG\", \"reason\": \"no-handoff-resolved\", \"detected_at\": \"$TODAY\"}"
  echo "binder-handoff-append-wrapper: no finalized handoff.md resolved for spoke [$SPOKE_ARG]; defensive skip (no append)" >&2
  exit 0
fi

# --- locate + invoke the orphaned appender hook ------------------------------
APPENDER=""
for cand in \
  "$CLAUDE_HOME_RES/hooks/handoff-chronicle-append.sh" \
  "$_REPO_ROOT/hooks/handoff-chronicle-append.sh"; do
  if [[ -x "$cand" ]]; then APPENDER="$cand"; break; fi
done

if [[ -z "$APPENDER" ]]; then
  emit_finding_line "{\"finding\": \"binder-handoff-append-wrapper-skipped\", \"spoke\": \"$SPOKE_ARG\", \"reason\": \"appender-not-installed\", \"detected_at\": \"$TODAY\"}"
  echo "binder-handoff-append-wrapper: handoff-chronicle-append.sh not installed; defensive skip" >&2
  exit 0
fi

# delegate the single sentinel-region append (positional args). The appender is
# itself block-and-log; pass FINDINGS_OUTPUT through so its findings land in the
# session-close per-run sink. A non-zero appender exit (a malformed/empty handoff)
# is a defensive skip, never a close-crash.
if PLANS_ROOT="$PLANS_ROOT" "$APPENDER" "$HANDOFF_PATH" "$SPOKE_ARG"; then
  exit 0
fi
emit_finding_line "{\"finding\": \"binder-handoff-append-wrapper-skipped\", \"spoke\": \"$SPOKE_ARG\", \"reason\": \"appender-blocked\", \"handoff\": \"$HANDOFF_PATH\", \"detected_at\": \"$TODAY\"}"
echo "binder-handoff-append-wrapper: appender block-and-logged (handoff $HANDOFF_PATH); defensive skip" >&2
exit 0
