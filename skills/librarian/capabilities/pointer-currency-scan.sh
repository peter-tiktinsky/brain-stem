#!/bin/bash
# pointer-currency-scan — Advisory currency check for plain-text absolute-path
# pointers in the memory tier (T-7; pointer architecture).
# Predicate INVERTS memory-staleness. memory-staleness asks "is last_validated
# past the interval?"; this asks "does each plain-text absolute-path pointer in
# MEMORY.md + memory topic-files + rules/*.md still RESOLVE on disk?". Propose-
# only, NO --fix. NDJSON via hooks/lib/findings.sh (finding name: pointer-currency).
# Scans the THREE plain-text-path classes NO existing cleaner covers:
#   - memory-consolidation-run.sh Check-5 only resolves markdown `[x](memory/x.md)`
#     index refs INSIDE MEMORY_DIR.
#   - rules-hygiene.sh dead-glob only flags `paths:` GLOBS.
#   - rename-cascade.sh only rewrites [[wikilinks]] + four named FM path keys.
#   Plain-text bare `/Users/.../foo.md` strings fall through all three.
# This is the FULL standalone capability — NOT a rename-cascade --scan-plain-text
# bolt-on (which fires only inside the 24h git-rename window and structurally
# cannot see manual vault restructures, OS-level renames, or correct-at-write-but-
# later-deleted targets).
# Cadence — CHANGE-GATED session-close. The scan fires at session-close ONLY
# when a tracked file (MEMORY.md / a memory topic-file / a rules/*.md) changed
# since the last scan — detected via a content-hash state file (the lychee
# .lycheecache / pre-commit changed-files analog; content-hash, not mtime, is
# deterministic across parallel invocations per feedback_guard_signal_determinism).
# SILENT no-op otherwise (NOT an unconditional every-session "all clear" — that
# trains the operator to ignore the advisory: the ESLint-warnings / Datadog
# alert-fatigue anti-pattern). First-ever run (no state file) RUNS. The state file
# is updated after each run. The state file is RUNTIME STATE under HOOKS_STATE —
# NOT manifest-managed.
# An ad-hoc invocation (no --session-close) ALWAYS runs (unconditional scan); the
# change-gate applies only to the session-close cadence.
# Recommended changes incorporated (verdict):
#   (a) Do NOT copy memory-staleness's TTY skip-non-interactive guard — session-
#       close is always model-invoked; gate ONLY on FOUNDATION_TEST_MODE.
#   (b) Registry cron_block = "none" — cadence is session-close, NOT cron.
#   (c) propose-only with NO --fix. The auto-fix "rename-cascade-known subset" is
#       DEFERRED (rename-cascade.sh has no plain-text-path mode today); filed as a
#       System Backlog row (T-8), not floated.
# Ephemeral paths (e.g. sessions/<sid>/checkpoint.md) are reported ADVISORY-SOFT
# (reason='ephemeral-by-design; expected to rotate'), NEVER suppress-listed — a
# suppress-list itself rots.
# Graceful degradation: MEMORY_DIR non-existent -> exit 0 + stderr note (modeled
# on memory-staleness). claude-mem absent has NO effect (the scanner reads files
# on disk).
# NDJSON schema (emit_finding):
#   { "finding": "pointer-currency", "file": "<source-basename>",
#     "category": "pointer-currency", "source": "<memory|rules>",
#     "target": "<missing-absolute-path>", "line": <int>, "level": "<warn|info>",
#     "reason": "..." }
# Tier: judgment (propose-only). Output Contract: propose-only; the adopter
# reviews via /librarian invocation. Cron block: none.
# CLI:
#   pointer-currency-scan.sh                 # ad-hoc — scan now, emit to sink/stdout
#   pointer-currency-scan.sh --session-close # change-gated cadence (silent if unchanged)
#   pointer-currency-scan.sh --scope <path>  # override MEMORY_DIR
#   pointer-currency-scan.sh --dry-run       # summary counts only
#   pointer-currency-scan.sh --print-state-file  # print the change-gate state path, exit
#   pointer-currency-scan.sh --help
# Env overrides:
#   MEMORY_DIR              Override session memory dir (else resolved via
#                           lib/paths.sh::resolve_memory_dir).
#   RULES_DIR               Override the rules dir (else $CLAUDE_HOME/rules).
#   FINDINGS_OUTPUT         (default: stdout)
#   HOOKS_STATE             Change-gate state-file home (HOOKS_STATE_OVERRIDE wins
#                           for test isolation — feedback_test_isolation_for_hooks_state).
#   FOUNDATION_TEST_MODE    Present for test/CI runners (no behavioral gate today;
#                           the TTY guard is intentionally OMITTED per change (a)).
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24
# ([[feedback_python_heredoc_argv]]).

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${MEMORY_DIR:-}" || -z "${HOOKS_STATE:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"

SCOPE=""
DRY_RUN="false"
SESSION_CLOSE="false"
PRINT_STATE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --session-close) SESSION_CLOSE="true"; shift ;;
    --print-state-file) PRINT_STATE="true"; shift ;;
    -h|--help) sed -n '2,72p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "pointer-currency-scan: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- resolve the memory dir (MEMORY_DIR env wins; else resolve_memory_dir) ----
if [[ -n "${MEMORY_DIR:-}" ]]; then
  : # caller override wins
elif command -v resolve_memory_dir >/dev/null 2>&1; then
  MEMORY_DIR="$(resolve_memory_dir 2>/dev/null || true)"
else
  MEMORY_DIR=""
fi
if [[ -n "$SCOPE" ]]; then
  MEMORY_DIR="$SCOPE"
fi
case "$MEMORY_DIR" in
  */) MEMORY_DIR="${MEMORY_DIR%/}" ;;
  *) : ;;
esac

# --- resolve the rules dir (RULES_DIR env wins; else $CLAUDE_HOME/rules) -------
RULES_DIR_RES="${RULES_DIR:-$CLAUDE_HOME_RES/rules}"

# --- resolve the change-gate state file (runtime state under HOOKS_STATE) ------
# HOOKS_STATE_OVERRIDE wins for test isolation (feedback_test_isolation_for_hooks_state);
# paths.sh already folds it into HOOKS_STATE when sourced, but honor it directly
# in case the lib is unreachable.
STATE_HOME="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-$CLAUDE_HOME_RES/hooks/state}}"
STATE_FILE="$STATE_HOME/pointer-currency-scan.cache"

# G5/D3 (plan 110 T-63): transitional new-first/old-fallback for the change-gate
# cache — ONE release (v1.3.0). If the cache is absent at the new HOOKS_STATE home
# but present at the OLD $CLAUDE_HOME/hooks/state, seed the new location from it so
# the content-hash gate does not spuriously re-fire mid-upgrade (alert-fatigue).
# Reads/writes thereafter target the new STATE_FILE. Skipped under
# HOOKS_STATE_OVERRIDE (test isolation). Removed in v1.4.0 (T-60).
_old_state_file="$CLAUDE_HOME_RES/hooks/state/pointer-currency-scan.cache"
if [[ -z "${HOOKS_STATE_OVERRIDE:-}" && ! -f "$STATE_FILE" \
      && -f "$_old_state_file" && "$_old_state_file" != "$STATE_FILE" ]]; then
  mkdir -p "$STATE_HOME" 2>/dev/null || true
  cp -p "$_old_state_file" "$STATE_FILE" 2>/dev/null || true
fi

if [[ "$PRINT_STATE" == "true" ]]; then
  echo "$STATE_FILE"
  exit 0
fi

# Graceful degradation: MEMORY_DIR absent -> exit 0 + stderr note.
if [[ -z "$MEMORY_DIR" || ! -d "$MEMORY_DIR" ]]; then
  echo "pointer-currency-scan: MEMORY_DIR does not exist: ${MEMORY_DIR:-<unset>}" >&2
  exit 0
fi

# The python3 pass does: (1) content-hash the tracked-file set; (2) for the
# session-close cadence, compare against the state file and SILENT no-op if
# unchanged; (3) scan every tracked file for plain-text absolute-path pointers
# and emit a finding for each non-resolving target; (4) update the state file.
# All data via argv (feedback_python_heredoc_argv).
python3 - "$MEMORY_DIR" "$RULES_DIR_RES" "$STATE_FILE" "$SESSION_CLOSE" "$DRY_RUN" <<'PY'
import hashlib
import json
import os
import re
import sys

memory_dir = sys.argv[1].rstrip("/")
rules_dir = sys.argv[2].rstrip("/")
state_file = sys.argv[3]
session_close = sys.argv[4] == "true"
dry_run = sys.argv[5] == "true"

# --- enumerate the tracked-file set -----------------------------------------
# Class membership (the three plain-text-path classes no existing cleaner covers):
#   - MEMORY.md (the index)
#   - every memory topic-file (*.md in MEMORY_DIR, EXCEPT MEMORY.md and the
#     runtime episodic chronicle files, which are not curated pointer carriers)
#   - every rules/*.md (the uncapped must-survive-pointer carrier)
def tracked_files():
    files = []
    if os.path.isdir(memory_dir):
        for entry in sorted(os.listdir(memory_dir)):
            if not entry.endswith(".md"):
                continue
            if entry.startswith("episodic-chronicle"):
                continue  # runtime-generated, not a curated pointer carrier
            full = os.path.join(memory_dir, entry)
            if os.path.isfile(full):
                files.append(full)
    if os.path.isdir(rules_dir):
        for entry in sorted(os.listdir(rules_dir)):
            if not entry.endswith(".md"):
                continue
            full = os.path.join(rules_dir, entry)
            if os.path.isfile(full):
                files.append(full)
    return files

files = tracked_files()

# --- content-hash the tracked set (deterministic change-gate signal) ---------
# Hash file-path + content for every tracked file, in sorted order. Content-hash
# (NOT most-recent-mtime) is deterministic across parallel invocations
# (feedback_guard_signal_determinism — mtime-most-recent is stochastic).
def corpus_hash():
    h = hashlib.sha256()
    for f in files:
        h.update(f.encode("utf-8", "replace"))
        h.update(b"\0")
        try:
            with open(f, "rb") as fh:
                h.update(fh.read())
        except OSError:
            pass
        h.update(b"\0")
    return h.hexdigest()

current_hash = corpus_hash()

# --- change-gate (session-close cadence only) --------------------------------
# First-ever run (no state file) RUNS. Unchanged corpus -> SILENT no-op. An
# ad-hoc invocation (not --session-close) ALWAYS runs. Update the state file
# AFTER a run.
def read_prev_hash():
    try:
        with open(state_file, encoding="utf-8") as fh:
            obj = json.load(fh)
        v = obj.get("corpus_hash")
        return v if isinstance(v, str) else None
    except (OSError, json.JSONDecodeError):
        return None

def write_state():
    try:
        os.makedirs(os.path.dirname(state_file), exist_ok=True)
        tmp = state_file + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"corpus_hash": current_hash}, fh)
        os.replace(tmp, state_file)
    except OSError:
        pass

if session_close:
    prev = read_prev_hash()
    if prev is not None and prev == current_hash:
        # Nothing tracked changed since the last scan — SILENT no-op (no findings,
        # NO "all clear"). Defeats alert-fatigue.
        sys.exit(0)

# --- the pointer-resolution scan ---------------------------------------------
# A plain-text absolute-path pointer is a bare absolute or tilde path token that
# resolves (or fails to resolve) on disk. We deliberately do NOT match markdown
# `[label](memory/x.md)` links (consolidation Check-5's domain) — only bare path
# strings. Tokenize each line and test path-like tokens. Tilde expands to $HOME.
HOME = os.environ.get("HOME", os.path.expanduser("~"))

# A path token: starts with / or ~ , ends at whitespace or a closing bracket/paren/
# quote/comma/backtick. Require at least one `/` after the root and a file-ish or
# dir-ish shape. We accept tokens ending in `.md`/`.json`/`.sh`/etc OR a directory.
PATH_TOKEN_RE = re.compile(r'(?<![\w`/])([~/][^\s`"\'\)\]\>,;]+)')

# Trailing punctuation that commonly abuts a path in prose.
TRAILING = ".,;:)]}>—`'\""

def expand(tok):
    if tok.startswith("~/"):
        return os.path.join(HOME, tok[2:])
    if tok == "~":
        return HOME
    return tok

# Markdown-link target guard: skip a `](...)` markdown-link target so we don't
# double-report relative `memory/x.md` refs (consolidation Check-5's class). We
# only scan BARE tokens, and a markdown target is preceded by `](` — exclude it.
MD_LINK_TARGET_RE = re.compile(r'\]\(([^)]+)\)')

# Ephemeral-by-design path classes: a still-rotating checkpoint/session-state path
# is reported ADVISORY-SOFT (level=info, reason names it), never suppressed.
EPHEMERAL_RE = re.compile(r'sessions/[^/]+/checkpoint\.md$|/checkpoint(-\d{8}-\d{6})?\.md$')

def emit(finding):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(finding, separators=(", ", ": "), sort_keys=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        print(line)

counts = {"scanned_files": 0, "scanned_pointers": 0, "missing": 0, "ephemeral": 0, "ok": 0}

for f in files:
    counts["scanned_files"] += 1
    base = os.path.basename(f)
    if os.path.realpath(os.path.dirname(f)) == os.path.realpath(rules_dir):
        source = "rules"
    else:
        source = "memory"
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError:
        continue
    for lineno, raw in enumerate(lines, start=1):
        # Strip markdown-link targets so a bare-token scan never re-reports the
        # `](memory/x.md)` relative-link class (consolidation Check-5's domain).
        scan_line = MD_LINK_TARGET_RE.sub(" ", raw)
        seen = set()
        for m in PATH_TOKEN_RE.finditer(scan_line):
            tok = m.group(1).rstrip(TRAILING)
            # Require an absolute/tilde path with at least one more segment.
            if tok in ("/", "~"):
                continue
            if "/" not in tok[1:]:
                continue
            # Only consider tokens that point at a concrete fs entry shape: must
            # carry a filename extension OR end without a trailing slash (a dir or
            # file). Skip obvious non-paths (URLs already excluded — they don't
            # start with / or ~; a `http(s)://` host is excluded by the leading
            # char guard).
            if tok in seen:
                continue
            seen.add(tok)
            counts["scanned_pointers"] += 1
            target = expand(tok)
            if os.path.exists(target):
                counts["ok"] += 1
                continue
            # Non-resolving. Ephemeral-by-design class -> advisory-soft (info),
            # never suppressed.
            if EPHEMERAL_RE.search(tok):
                counts["ephemeral"] += 1
                if not dry_run:
                    emit({
                        "finding": "pointer-currency",
                        "file": base,
                        "category": "pointer-currency",
                        "source": source,
                        "target": tok,
                        "line": lineno,
                        "level": "info",
                        "reason": "ephemeral-by-design; expected to rotate (target absent: %s)" % target,
                    })
            else:
                counts["missing"] += 1
                if not dry_run:
                    emit({
                        "finding": "pointer-currency",
                        "file": base,
                        "category": "pointer-currency",
                        "source": source,
                        "target": tok,
                        "line": lineno,
                        "level": "warn",
                        "reason": "plain-text absolute-path pointer does not resolve on disk: %s" % target,
                    })

# Update the change-gate state file after a run (both cadences).
write_state()

if dry_run:
    print("pointer-currency-scan: dry-run summary (memory=%s rules=%s)" % (memory_dir, rules_dir), file=sys.stderr)
    print("  files=%d pointers=%d  missing=%d  ephemeral=%d  ok=%d" % (
        counts["scanned_files"], counts["scanned_pointers"],
        counts["missing"], counts["ephemeral"], counts["ok"],
    ), file=sys.stderr)
PY

exit 0
