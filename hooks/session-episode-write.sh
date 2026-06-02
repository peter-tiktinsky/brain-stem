#!/bin/bash
# Hook: SessionEnd — author the episodic-tier session-outcome record.
#
# Episode_* files are hook-authored at SessionEnd. This is the PRODUCER of the
# episodic tier (1 of the retrieval triad: semantic | procedural |
# episodic); without it the episodic section of MEMORY.md is structurally empty.
#
# Output Contract (memory-schema.json 2.0.0):
#   - Files written: <memory-dir>/episode_<session>-<ts>.md
#   - Frontmatter: type: episodic (hard-locked, hook-enforced) + the required
#     memory-schema fields (name, description, type, tags, created, updated,
#     last_validated). episode_ provenance prefix -> episodic type.
#   - Body: CoALA shape (## Situation / ## Thought / ## Action / ## Result),
#     per memory-schema _design_notes.episode_episodic_coala.
#   - Pre-write validation: minimal frontmatter presence (the hook emits a
#     conformant block by construction; pre-write-guard R-45 re-validates).
#   - Failure mode: block-and-log — graceful no-op (exit 0) when there is no
#     session context or no resolvable memory dir; never fail-hard.
#
# Graceful no-op when $CLAUDE_SESSION_ID (and stdin .session_id) are absent.
set -uo pipefail

# Portability: resolve libs via $SCRIPT_DIR. paths.sh provides
# resolve_memory_dir; registry.sh provides the session row (touched files).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null

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

# Auto-memory layout is <memory-dir>/*.md (MEMORY.md index + per-fact files).
# resolve_memory_dir returns the directory that holds MEMORY.md, so episode
# files land beside the index.
DEST_DIR="$MEM_DIR"

DATE_STAMP=$(date +"%Y-%m-%d")
TS=$(date -u +"%Y%m%d-%H%M%S")
SID_SHORT="$(printf '%s' "$SESSION_ID" | tr -cd 'a-zA-Z0-9' | cut -c1-8)"
[ -z "$SID_SHORT" ] && SID_SHORT="session"
EPISODE_NAME="episode_${SID_SHORT}-${TS}"
EPISODE_FILE="$DEST_DIR/${EPISODE_NAME}.md"

# Gather the touched-file count from the registry row (best-effort signal).
touched_count=0
if command -v jq >/dev/null 2>&1 && command -v read_registry >/dev/null 2>&1; then
  reg=$(read_registry 2>/dev/null || true)
  if [ -n "$reg" ]; then
    touched_count=$(printf '%s' "$reg" | jq -r --arg s "$SESSION_ID" \
      '(.sessions[$s].touched_files // []) | length' 2>/dev/null || echo 0)
  fi
fi
[ -z "$touched_count" ] && touched_count=0

# Compose the episode record. type: episodic is hard-locked. The body
# follows the CoALA Situation/Thought/Action/Result shape; the hook fills factual
# session-outcome lines (no LLM) — a model-authored episode may later enrich it.
tmp="${EPISODE_FILE}.tmp.$$"
{
  printf -- '---\n'
  printf 'name: %s\n' "$EPISODE_NAME"
  printf 'description: "Session %s outcome record (%s touched file(s)); auto-captured at SessionEnd."\n' "$SID_SHORT" "$touched_count"
  printf 'type: episodic\n'
  printf 'tags: ["#episode/session"]\n'
  printf 'created: %s\n' "$DATE_STAMP"
  printf 'updated: %s\n' "$DATE_STAMP"
  printf 'last_validated: %s\n' "$DATE_STAMP"
  printf 'source_session_id: %s\n' "$SESSION_ID"
  printf -- '---\n\n'
  printf '## Situation\n'
  printf 'Session %s ended; %s file(s) touched this session.\n\n' "$SID_SHORT" "$touched_count"
  printf '## Thought\n'
  printf 'Auto-captured session-outcome record (CoALA episodic tier). Enrich on review.\n\n'
  printf '## Action\n'
  printf 'Recorded the SessionEnd episode into the curated memory tier.\n\n'
  printf '## Result\n'
  printf 'Episodic record persisted; available for retrieval + consolidation.\n'
} > "$tmp" 2>/dev/null || exit 0

mv "$tmp" "$EPISODE_FILE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }

exit 0
