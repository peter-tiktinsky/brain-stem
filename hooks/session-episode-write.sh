#!/bin/bash
# Hook: SessionEnd — author the episodic-tier session-outcome record.
# C5-owned body in a C2 slot (canonical/SessionEnd: session-deregister
# -> session-episode-write;.12: episodic capture hook-authored at
# SessionEnd — data = C5, trigger slot = C2). This is the PRODUCER of the
# episodic tier (1 of the retrieval triad: semantic | procedural |
# episodic); without it the episodic section of MEMORY.md is structurally empty.
# Output Contract (memory-schema.json 2.1.0 + chronicle reversal):
#   - Files written (TWO-FILE MODEL, both NO-LLM):
#       1. <memory-dir>/episodic-chronicle.md — append-only, newest-first; one
#          harvested row PREPENDED per session (created-with-header on first
#          write). Atomic temp+rename. type: episodic frontmatter so the
#          staleness scan skips it (memory-consolidation-run.sh:174).
#       2. <memory-dir>/MEMORY.md — a sentinel-bounded single POINTER LINE in the
#          `## Episodic` section (above the 200-line/25KB fold), refreshed
#          idempotently each session. Embeds the literal `episodic-chronicle.md`
#          so the orphan-adder (memory-consolidation-run.sh:209 substring grep)
#          treats the chronicle as already-indexed and self-skips it.
#   - Row fields (ALL no-LLM, harvested at SessionEnd):
#       Anchor   = cwd->git-slug + ISO date + plan/phase (checkpoint -> plan-path
#                  classify -> `— none —`).
#       Touched  = `touched: <COUNT> file(s) on <branch>` (COUNT from the registry
#                  row; branch via git rev-parse --abbrev-ref HEAD).
#       Next     = the verbatim `**Next session:**` line harvested from the
#                  close-out/handoff (no-LLM python3 argv line-harvest).
#       Summary  = the LITERAL placeholder `— summary on review —`; the
#                  chronicle-index capability BACKFILLS it at librarian
#                  session-close. The hook NEVER parses transcript_path.
#       Slots    = 3 optional pointer slots (handoff / checkpoint / claude-mem),
#                  each rendered only after on-disk resolution; `— none —` on
#                  absence (NEVER a dangling link). The claude-mem slot pins the
#                  content_session_id UUID via source_session_id, never the
#                  renumberable `#S` ids. A machine-canonical
#                  `slots: {handoff,checkpoint,claude_mem}` presence map is
#                  carried in the row frontmatter ALONGSIDE the `— none —` render.
#   - Failure mode: block-and-log — graceful no-op (exit 0) when there is no
#     session context or no resolvable memory dir; never fail-hard. Atomic
#     temp+rename so a 5s-timeout truncation cannot corrupt the chronicle.
# Graceful no-op when $CLAUDE_SESSION_ID (and stdin .session_id) are absent.
set -uo pipefail

# Portability (/ LOCK): resolve libs via $SCRIPT_DIR. paths.sh provides
# resolve_memory_dir + the git-root-else-physical-cwd slug anchor + PLANS_DIR /
# SESSION_STATE_ROOT; registry.sh provides the session row (touched files);
# plan-path.sh provides classify_plan_path (plan/phase fallback).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null
[ -r "$SCRIPT_DIR/lib/plan-path.sh" ] && source "$SCRIPT_DIR/lib/plan-path.sh" 2>/dev/null

# Drain stdin (SessionEnd JSON payload) so we never block.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi

# Graceful no-op: no session context.
[ -z "$SESSION_ID" ] && exit 0

# Resolve the memory dir. MEMORY_DIR env (test/CI) wins inside resolve_memory_dir.
MEM_DIR="$(resolve_memory_dir 2>/dev/null || true)"
[ -z "$MEM_DIR" ] && exit 0
mkdir -p "$MEM_DIR/memory" 2>/dev/null || mkdir -p "$MEM_DIR" 2>/dev/null || exit 0

# resolve_memory_dir returns the directory that holds MEMORY.md; the chronicle
# lands FLAT beside the index so the substring-grep orphan-adder self-skips it.
DEST_DIR="$MEM_DIR"
CHRONICLE_FILE="$DEST_DIR/episodic-chronicle.md"
INDEX_FILE="$DEST_DIR/MEMORY.md"

DATE_STAMP=$(date +"%Y-%m-%d")
SID_SHORT="$(printf '%s' "$SESSION_ID" | tr -cd 'a-zA-Z0-9' | cut -c1-8)"
[ -z "$SID_SHORT" ] && SID_SHORT="session"

# --- Anchor: git-root-else-physical-cwd slug (mirrors paths.sh:180-187) -------
PHYS="$(pwd -P 2>/dev/null)" || PHYS="$(pwd)"
GIT_ROOT="$(git -C "$PHYS" rev-parse --show-toplevel 2>/dev/null)" || GIT_ROOT=""
[ -n "$GIT_ROOT" ] || GIT_ROOT="$PHYS"
GIT_SLUG="$(printf '%s' "$GIT_ROOT" | sed 's/[^a-zA-Z0-9]/-/g')"

# --- Branch (best-effort; no-LLM, <50ms) --------------------------------------
BRANCH="$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -z "$BRANCH" ] && BRANCH="— none —"

# --- Touched-file count from the registry row (best-effort no-LLM signal) -----
touched_count=0
if command -v jq >/dev/null 2>&1 && command -v read_registry >/dev/null 2>&1; then
  reg=$(read_registry 2>/dev/null || true)
  if [ -n "$reg" ]; then
    touched_count=$(printf '%s' "$reg" | jq -r --arg s "$SESSION_ID" \
      '(.sessions[$s].touched_files // []) | length' 2>/dev/null || echo 0)
  fi
fi
[ -z "$touched_count" ] && touched_count=0

# --- Plan/phase: checkpoint.md (flat scalars) -> plan-path classify -> none ---
# Stat-only resolution; bounded head read of the checkpoint (no full parse).
PLAN_PHASE="— none —"
cp_plan=""
cp_phase=""
CHECKPOINT_FILE="${SESSION_STATE_ROOT:-$CLAUDE_STATE_ROOT}/sessions/$SESSION_ID/checkpoint.md"
if [ -r "$CHECKPOINT_FILE" ]; then
  cp_plan="$(head -c 4096 "$CHECKPOINT_FILE" 2>/dev/null | sed -n 's/^plan_id:[[:space:]]*//p' | head -1)"
  cp_phase="$(head -c 4096 "$CHECKPOINT_FILE" 2>/dev/null | sed -n 's/^phase:[[:space:]]*//p' | head -1)"
  case "$cp_plan" in ""|"[MISSING]") cp_plan="" ;; esac
  case "$cp_phase" in ""|"[MISSING]") cp_phase="" ;; esac
  if [ -n "$cp_plan" ] && [ -n "$cp_phase" ]; then
    PLAN_PHASE="${cp_plan} / ${cp_phase}"
  elif [ -n "$cp_plan" ]; then
    PLAN_PHASE="$cp_plan"
  fi
fi
# Fallback: classify the cwd against PLANS_DIR (1|0|<slug> => plan slug).
if [ "$PLAN_PHASE" = "— none —" ] && command -v classify_plan_path >/dev/null 2>&1; then
  ps_info="$(classify_plan_path "$PHYS/spec.md" 2>/dev/null || true)"
  ps_is_plan="${ps_info%%|*}"
  ps_top="${ps_info##*|}"
  if [ "$ps_is_plan" = "1" ] && [ -n "$ps_top" ]; then
    PLAN_PHASE="$ps_top"
  fi
fi

# --- Next-session line: verbatim `**Next session:**` from close-out/handoff ----
# No-LLM python3 argv line-harvest (per feedback_python_heredoc_argv: pass via
# argv, NEVER pipe to a heredoc). Resolve the handoff path first (also the slot).
HANDOFF_FILE=""
if [ -n "${PLANS_DIR:-}" ] && [ -n "$cp_plan" ] && [ -r "$PLANS_DIR/$cp_plan/handoff.md" ]; then
  HANDOFF_FILE="$PLANS_DIR/$cp_plan/handoff.md"
elif [ -n "${PLANS_DIR:-}" ] && [ "$PLAN_PHASE" != "— none —" ] && [ -r "$PLANS_DIR/$PLAN_PHASE/handoff.md" ]; then
  HANDOFF_FILE="$PLANS_DIR/$PLAN_PHASE/handoff.md"
fi
NEXT_SESSION="— none —"
if [ -n "$HANDOFF_FILE" ] && [ -r "$HANDOFF_FILE" ] && command -v python3 >/dev/null 2>&1; then
  harvested="$(python3 - "$HANDOFF_FILE" <<'PY'
import re, sys
path = sys.argv[1]
# Word-boundary harvest of the verbatim `**Next session:**` line (first hit).
hit_re = re.compile(r"\*\*Next session:\*\*\s*(.+?)\s*$")
try:
    with open(path) as f:
        lines = f.readlines()
except Exception:
    sys.exit(0)
for line in lines:
    m = hit_re.search(line)
    if m and m.group(1).strip():
        print(m.group(1).strip())
        break
PY
)"
  [ -n "$harvested" ] && NEXT_SESSION="$harvested"
fi

# --- 3 optional pointer slots (fill-if-available; `— none —` on absence) -------
# handoff slot — resolved above.
SLOT_HANDOFF="— none —"; HAVE_HANDOFF=false
if [ -n "$HANDOFF_FILE" ] && [ -r "$HANDOFF_FILE" ]; then
  SLOT_HANDOFF="$HANDOFF_FILE"; HAVE_HANDOFF=true
fi

# checkpoint slot — the per-session checkpoint.md (ephemeral; flags staleness).
SLOT_CHECKPOINT="— none —"; HAVE_CHECKPOINT=false
if [ -r "$CHECKPOINT_FILE" ]; then
  SLOT_CHECKPOINT="$CHECKPOINT_FILE"; HAVE_CHECKPOINT=true
fi

# claude-mem slot — pin the content_session_id UUID via source_session_id, NEVER
# the renumberable `#S` ids. Resolved ONLY when the claude-mem db is reachable.
SLOT_CLAUDE_MEM="— none —"; HAVE_CLAUDE_MEM=false
CLAUDE_MEM_DB="${CLAUDE_MEM_DB:-$HOME/.claude-mem/claude-mem.db}"
if [ -f "$CLAUDE_MEM_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  cm_hit="$(sqlite3 "$CLAUDE_MEM_DB" \
    "SELECT 1 FROM sdk_sessions WHERE content_session_id='$SESSION_ID' LIMIT 1;" 2>/dev/null || true)"
  if [ -n "$cm_hit" ]; then
    SLOT_CLAUDE_MEM="claude-mem session-summary (source_session_id: $SESSION_ID)"
    HAVE_CLAUDE_MEM=true
  fi
fi

# --- Compose the chronicle row (newest-first PREPEND) -------------------------
# Build the new row, then create-with-header or prepend it atomically.
CHRON_HEADER='---
name: episodic-chronicle
description: "Append-only newest-first no-LLM session chronicle (one row per session). Anchors, touched-counts, Next-session lines, resume pointers."
type: episodic
tags: ["#episode/session", "#chronicle"]
created: '"$DATE_STAMP"'
updated: '"$DATE_STAMP"'
last_validated: '"$DATE_STAMP"'
---

# Episodic Chronicle

Append-only, newest-first. One no-LLM row per session, harvested at SessionEnd.
'

tmp_row="$DEST_DIR/.chronicle-row.$$.tmp"
{
  printf -- '<!-- chronicle-row %s %s -->\n' "$SID_SHORT" "$DATE_STAMP"
  printf -- '## %s — %s\n' "$DATE_STAMP" "$GIT_SLUG"
  printf -- '- slots: {handoff: %s, checkpoint: %s, claude_mem: %s}\n' "$HAVE_HANDOFF" "$HAVE_CHECKPOINT" "$HAVE_CLAUDE_MEM"
  printf -- '- **Anchor:** %s · %s · %s\n' "$GIT_SLUG" "$DATE_STAMP" "$PLAN_PHASE"
  printf -- '- **Touched:** touched: %s file(s) on %s\n' "$touched_count" "$BRANCH"
  printf -- '- **Next session:** %s\n' "$NEXT_SESSION"
  printf -- '- **Summary:** — summary on review —\n'
  printf -- '- **handoff:** %s\n' "$SLOT_HANDOFF"
  printf -- '- **checkpoint:** %s\n' "$SLOT_CHECKPOINT"
  printf -- '- **claude-mem:** %s\n' "$SLOT_CLAUDE_MEM"
  printf -- '\n'
} > "$tmp_row" 2>/dev/null || { rm -f "$tmp_row" 2>/dev/null; exit 0; }

tmp_chron="$CHRONICLE_FILE.tmp.$$"
if [ -f "$CHRONICLE_FILE" ]; then
  # Split the existing file at the first chronicle row (after the header block)
  # and prepend the new row above the existing rows, preserving the header.
  if grep -q '<!-- chronicle-row ' "$CHRONICLE_FILE" 2>/dev/null; then
    {
      # header = everything before the first `<!-- chronicle-row `
      sed '/<!-- chronicle-row /,$d' "$CHRONICLE_FILE"
      cat "$tmp_row"
      # existing rows = from the first `<!-- chronicle-row ` to EOF
      sed -n '/<!-- chronicle-row /,$p' "$CHRONICLE_FILE"
    } > "$tmp_chron" 2>/dev/null || { rm -f "$tmp_row" "$tmp_chron" 2>/dev/null; exit 0; }
  else
    # File exists but has no rows yet (header-only) — append the row after it.
    {
      cat "$CHRONICLE_FILE"
      cat "$tmp_row"
    } > "$tmp_chron" 2>/dev/null || { rm -f "$tmp_row" "$tmp_chron" 2>/dev/null; exit 0; }
  fi
else
  # First write — create-with-header then the row.
  {
    printf -- '%s\n' "$CHRON_HEADER"
    cat "$tmp_row"
  } > "$tmp_chron" 2>/dev/null || { rm -f "$tmp_row" "$tmp_chron" 2>/dev/null; exit 0; }
fi
rm -f "$tmp_row" 2>/dev/null
mv "$tmp_chron" "$CHRONICLE_FILE" 2>/dev/null || { rm -f "$tmp_chron" 2>/dev/null; exit 0; }

# --- Refresh the sentinel-bounded pointer line in MEMORY.md ## Episodic --------
# The pointer is idempotent: a sentinel-bounded block re-derived each session.
# The line embeds the literal `episodic-chronicle.md` (self-immunizes against the
# orphan-adder substring grep) and is shaped for's AND-gate placement guard:
#   (a) NOT a markdown list-link; (b) begins with a bare absolute path; (c) a
#   word-bounded imperative read verb; carries a why-clause.
POINTER_LINE="${CHRONICLE_FILE} — Read this append-only newest-first session chronicle for the last N sessions' anchors, Next-session lines, and resume pointers."
PTR_START='<!-- episodic-chronicle-pointer:start -->'
PTR_END='<!-- episodic-chronicle-pointer:end -->'

if [ -f "$INDEX_FILE" ] && grep -q '^## Episodic' "$INDEX_FILE" 2>/dev/null; then
  tmp_idx="$INDEX_FILE.tmp.$$"
  # Two-branch sentinel re-derive (mirrors index-maintain.sh idempotency): if the
  # sentinel block exists, replace it in place; else insert it right under the
  # `## Episodic` header (top of section, above the fold). awk -v single-line.
  if grep -qF "$PTR_START" "$INDEX_FILE" 2>/dev/null; then
    awk -v s="$PTR_START" -v e="$PTR_END" -v line="$POINTER_LINE" '
      $0 == s { print s; print line; print e; skip=1; next }
      $0 == e { skip=0; next }
      skip { next }
      { print }
    ' "$INDEX_FILE" > "$tmp_idx" 2>/dev/null && mv "$tmp_idx" "$INDEX_FILE" 2>/dev/null || rm -f "$tmp_idx" 2>/dev/null
  else
    awk -v s="$PTR_START" -v e="$PTR_END" -v line="$POINTER_LINE" '
      { print }
      /^## Episodic/ && !done { print ""; print s; print line; print e; done=1 }
    ' "$INDEX_FILE" > "$tmp_idx" 2>/dev/null && mv "$tmp_idx" "$INDEX_FILE" 2>/dev/null || rm -f "$tmp_idx" 2>/dev/null
  fi
fi

exit 0
