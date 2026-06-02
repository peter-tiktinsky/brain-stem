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
#   - created:        bootstrapped to today if absent; immutable post-bootstrap
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

INPUT=$(cat)
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

python3 - "$FILE_PATH" "$TODAY" <<'PY' 2>/dev/null || true
import sys
import os
import re

file_path = sys.argv[1]
today = sys.argv[2]

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

if 'created' not in keys_seen:
    set_key('created', today)

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
