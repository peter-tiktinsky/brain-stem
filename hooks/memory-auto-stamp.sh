#!/bin/bash
# Hook: PostToolUse (Edit|Write) — Auto-stamp memory file frontmatter.
#
# Part of the foundation memory substrate. Builds the staleness signal consumed
# by the librarian memory-staleness check without requiring adopter discipline.
# Fires only on writes under ~/.claude/projects/<slug>/memory/*.md (excludes
# MEMORY.md — the index hygiene rule covers the index separately).
#
# Behavior on memory topic-file writes:
#   - updated:        always stamped to today (UTC, YYYY-MM-DD); replaces existing value
#   - created:        bootstrapped to a DERIVED FLOOR if absent; immutable post-bootstrap.
#                     The floor is claude-mem's `metadata.modified`, else the git-added
#                     date, else today — see the derivation block below for the ordering
#                     and for why mtime is not a candidate.
#   - created_provenance: emitted ALONGSIDE a bootstrapped `created:` only, naming which
#                     branch produced it (derived-metadata-modified / derived-git-added /
#                     bootstrap-write-date). Absent == the `created:` value was observed,
#                     not derived. Never added to a file that already carries `created:`.
#   - last_validated: bootstrapped to created date if absent; preserved on rewrite
#
# Skip conditions (silent, never block): non-memory path, MEMORY.md, file missing,
# non-markdown, no frontmatter, malformed/non-parseable frontmatter, python3 missing,
# content already idempotent (no rewrite needed).
#
# Reference: schemas/memory-schema.json properties.{created,updated,last_validated}.
# Runs as PostToolUse (not PreToolUse): content rewrite requires PostToolUse per
# the pre-write-guard read-only-on-content contract.
set -euo pipefail

# Read the PostToolUse payload (the written file path).
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
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

[[ -z "$FILE_PATH" ]] && exit 0

# Match $HOME/.claude/projects/<slug>/memory/<file>.md; exclude the MEMORY.md index.
case "$FILE_PATH" in
  "$HOME"/.claude/projects/*/memory/*.md) ;;
  *) exit 0 ;;
esac
[[ "$FILE_PATH" == */MEMORY.md ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

TODAY=$(date -u +%Y-%m-%d)

command -v python3 >/dev/null 2>&1 || exit 0

# --- created: floor derivation (BOOTSTRAP PATH ONLY) -------------------------
# DERIVE-A-FLOOR, never MINT-TODAY. Two writers own these files with different
# frontmatter shapes: claude-mem authors memory nodes with a `metadata:` block and NO
# `created:`, so the first brain-stem-side Edit/Write used to mint `today` and manufacture
# a false birth date for content that predates it. Preference order (identical in
# post-write-verify.sh — keep the two in lockstep):
#   1. claude-mem's own `metadata.modified` — the other writer's in-band origin claim.
#   2. the git-added date — an independent external record, where the corpus is tracked.
#   3. no floor -> today, LABELLED as a bootstrap.
# mtime is deliberately NOT a candidate: this hook is PostToolUse, so the file was just
# written and its mtime IS today by construction — using it would re-implement mint-today
# under a derived label. A candidate is accepted only if it is STRICTLY EARLIER than today;
# a candidate equal to today carries no evidence the file predates this write.
# Whichever branch fires, `created_provenance:` records it, so a downstream sweep can tell a
# derived date from an observed one. Absence of the key == the value was author-observed.
# Cost: the frontmatter pre-read + git call run ONLY when `created:` is absent (the rare
# bootstrap path); the steady state is one awk + one grep.
CREATED_GIT_FLOOR=""
_mas_fm="$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$FILE_PATH" 2>/dev/null)"
if ! printf '%s\n' "$_mas_fm" | grep -qE '^created:'; then
  if command -v git >/dev/null 2>&1; then
    _mas_dir="$(dirname "$FILE_PATH")"
    if git -C "$_mas_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      CREATED_GIT_FLOOR="$(git -C "$_mas_dir" log --diff-filter=A --format=%ad --date=short \
        -- "$FILE_PATH" 2>/dev/null | tail -1)"
      [ -n "$CREATED_GIT_FLOOR" ] || CREATED_GIT_FLOOR="$(git -C "$_mas_dir" log \
        --format=%ad --date=short -- "$FILE_PATH" 2>/dev/null | tail -1)"
    fi
  fi
fi

python3 - "$FILE_PATH" "$TODAY" "$CREATED_GIT_FLOOR" <<'PY' 2>/dev/null || true
import sys
import os
import re

file_path = sys.argv[1]
today = sys.argv[2]
git_floor = sys.argv[3] if len(sys.argv) > 3 else ''

try:
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
except OSError:
    sys.exit(0)

if not content.startswith('---\n'):
    sys.exit(0)
end = content.find('\n---\n', 4)
if end < 0:
    sys.exit(0)

fm_text = content[4:end]
body = content[end + 5:]

# Line-oriented parse: <key>: <value>. Preserves original line order +
# non-key lines (blank lines, comments) + value-side formatting. Avoids
# round-tripping through PyYAML (which would reorder keys + strip comments).
KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')
lines = fm_text.split('\n')
keys_seen = {}
for idx, line in enumerate(lines):
    m = KEY_RE.match(line)
    if m:
        keys_seen[m.group(1)] = idx

if not keys_seen:
    sys.exit(0)

def set_key(key, value):
    if key in keys_seen:
        lines[keys_seen[key]] = f'{key}: {value}'
    else:
        lines.append(f'{key}: {value}')
        keys_seen[key] = len(lines) - 1

set_key('updated', today)

# ---- created: DERIVE-A-FLOOR (bootstrap path only) -------------------------
# Preference order + the mtime rejection are stated at the bash-side derivation
# block above. An existing `created:` is never read, never re-stamped, and never
# gains a `created_provenance:` — the observed-created cohort is byte-untouched.
DATE_RE = re.compile(r'^(\d{4}-\d{2}-\d{2})')
NESTED_RE = re.compile(r'^[ \t]+([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')


def metadata_modified_date():
    """claude-mem's in-band origin claim: the `modified:` key nested under `metadata:`."""
    if 'metadata' not in keys_seen:
        return ''
    for ln in lines[keys_seen['metadata'] + 1:]:
        if not ln.strip():
            continue
        m = NESTED_RE.match(ln)
        if not m:
            break  # de-indented — end of the metadata block
        if m.group(1) == 'modified':
            d = DATE_RE.match(m.group(2).strip().strip('"').strip("'"))
            return d.group(1) if d else ''
    return ''


def derive_created_floor():
    for value, source in ((metadata_modified_date(), 'derived-metadata-modified'),
                          (git_floor.strip(), 'derived-git-added')):
        if value and DATE_RE.match(value) and value[:10] < today:
            return value[:10], source
    return today, 'bootstrap-write-date'


if 'created' not in keys_seen:
    floor, floor_source = derive_created_floor()
    set_key('created', floor)
    set_key('created_provenance', floor_source)

if 'last_validated' not in keys_seen:
    created_line = lines[keys_seen['created']]
    m = KEY_RE.match(created_line)
    created_val = m.group(2).strip() if m else today
    set_key('last_validated', created_val)

new_fm = '\n'.join(lines)
new_content = f'---\n{new_fm}\n---\n{body}'

if new_content == content:
    sys.exit(0)

tmp_path = file_path + '.auto-stamp.tmp'
try:
    with open(tmp_path, 'w', encoding='utf-8') as f:
        f.write(new_content)
    os.replace(tmp_path, file_path)
except OSError:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    sys.exit(0)
PY

exit 0
