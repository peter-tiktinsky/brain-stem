#!/bin/bash
# Hook: PostToolUse (Edit|Write) — vault-write verify + Logs/ auto-governance.
#
# PostToolUse Edit|Write fire-order #2:
# track-vault-write -> post-write-verify -> memory-auto-stamp ->
# memory-globalize-auto.
#
# TRIPLE load-bearing:
#   1. The wired PostToolUse Edit|Write body.
#   2. Logs/ write-time AUTO-GOVERN branch (R-09: Logs/ is a
#      free-write scratch sink where governance is AUTO-APPLIED at write-time —
#      never denied, never propose-and-confirm). On a vault `Logs/**/*.md` write
#      lacking the minimal `log` contract, backfill type/log-type/date/timestamp
#      + the R-47 findability tag IN PLACE, preserving existing keys. Tier name =
#      `autogovern`. Defaults: log-type default = `documentation`;
#      skip the R-47 exempt set; the second (auto-stamp) write on Logs/ scratch
#      is acceptable. Only the hook branch is authored here.
#   3. R-44 _index Tier-1 vehicle — the regen entry-point is invocable here; the
#      session-close CHAINING of it is out of scope.
#
# Loop-guard: the auto-stamp writes via a direct filesystem os.replace (NOT the
# Edit/Write tool), so it does not itself re-fire PostToolUse; an explicit env
# sentinel (POST_WRITE_VERIFY_AUTOSTAMP_GUARD) + an idempotence check are belt-
# and-suspenders so a re-fire on an already-conformant file is a no-op.
#
# NEVER deny, NEVER fail-hard; exit 0 always.
set -uo pipefail

# Portability: resolve libs via $SCRIPT_DIR. paths.sh provides
# VAULT_LOGS resolution; the governance JSON contracts live under $CLAUDE_HOME.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0

GOV_DIR="${GOVERNANCE_DIR:-${CLAUDE_HOME:-$HOME/.claude}/governance}"

# --- R-44 Tier-1 _index regen entry-point (invocable) ------
# The vault-health _index regen vehicle. The session-close chain (R-44)
# invokes this; here it is authored as an invocable entry-point only. Delegates
# to the librarian index-maintain capability when present (Tier-2), else no-op.
post_write_verify_index_regen() {
  local target="${1:-}"
  local cap="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/index-maintain.sh"
  if [ -x "$cap" ]; then
    "$cap" "$target" >/dev/null 2>&1 || true
  fi
  return 0
}

# Internal entry-point so the regen vehicle is directly invocable:
# `post-write-verify.sh --index-regen [path]`.
if [ "${1:-}" = "--index-regen" ]; then
  post_write_verify_index_regen "${2:-}"
  exit 0
fi

# --- Read the PostToolUse payload (the written file path) --------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi
command -v jq >/dev/null 2>&1 || exit 0

FILE_PATH=""
if [ -n "$INPUT" ]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
fi
[ -z "$FILE_PATH" ] && exit 0
[ -f "$FILE_PATH" ] || exit 0

# Loop-guard sentinel: if our own auto-stamp re-entered the hook, no-op.
[ -n "${POST_WRITE_VERIFY_AUTOSTAMP_GUARD:-}" ] && exit 0

# --- Logs/ auto-govern branch ------------------------------------------------
# Scope: vault Logs/**/*.md only. VAULT_LOGS is empty when no vault is
# configured (graceful-degrade — paths.sh has no install default for it).
[ -z "${VAULT_LOGS:-}" ] && exit 0
case "$FILE_PATH" in
  "$VAULT_LOGS"/*.md) ;;
  *) exit 0 ;;
esac

# Relative path under Logs/ (e.g. "wikilink-repair-2026-05-30.md",
# "foundations-essays/x.md") for the exempt match.
REL="${FILE_PATH#$VAULT_LOGS/}"

# Exempt set (planner-encoded rec — honor existing R-47 exemptions; scratch-by-
# design): the R-47 r47_exempt_paths Logs/ entries + _index.md + librarian-
# manifest*. tagging-rules.json :: r47_exempt_paths Logs/ members are
# foundations-essays/**, ideation-brief-*.md, build-*.
base="${REL##*/}"
case "$REL" in
  foundations-essays/*|ideation-brief-*.md|build-*|*/_index.md|_index.md) exit 0 ;;
esac
case "$base" in
  _index.md|librarian-manifest*|librarian-manifest.json) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0

DATE_STAMP=$(date +"%Y-%m-%d")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Resolve a default log-subtype. Planner-encoded rec: default `documentation`
# (a seeded subtype in governance/log-subtype-registry.json). A path/owner-
# derived resolution can refine this later; v1 uses the generic fallback.
LOG_SUBTYPE="documentation"

# Survivorship-safe, line-oriented frontmatter backfill (mirrors the
# memory-auto-stamp.sh pattern): preserve existing keys + order + non-key lines;
# add only the missing log-contract keys; add the R-47 findability tag when tags
# is absent. Direct os.replace write (not the Edit tool) so PostToolUse does not
# re-fire. Idempotent: a fully-conformant file is left untouched.
POST_WRITE_VERIFY_AUTOSTAMP_GUARD=1 \
python3 - "$FILE_PATH" "$DATE_STAMP" "$TIMESTAMP" "$LOG_SUBTYPE" <<'PY' 2>/dev/null || true
import sys, os, re

file_path, date_stamp, timestamp, subtype = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
except OSError:
    sys.exit(0)

KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')

# Parse (or synthesize) the frontmatter block.
if content.startswith('---\n'):
    end = content.find('\n---\n', 4)
    if end < 0:
        # Opening fence but no close — do not guess; leave untouched.
        sys.exit(0)
    fm_text = content[4:end]
    body = content[end + 5:]
    had_fm = True
else:
    fm_text = ''
    body = content
    had_fm = False

lines = fm_text.split('\n') if fm_text else []
keys_seen = {}
for idx, line in enumerate(lines):
    m = KEY_RE.match(line)
    if m:
        keys_seen[m.group(1)] = idx

def set_key(key, value):
    if key in keys_seen:
        return  # survivorship: never clobber an existing key
    lines.append(f'{key}: {value}')
    keys_seen[key] = len(lines) - 1

# The minimal `log` contract (frontmatter-rules.json :: log.required) + the
# R-47 findability tag. Only missing keys are added.
set_key('type', 'log')
# log-type: preserve any existing value; the tag uses the resolved subtype.
existing_subtype = None
if 'log-type' in keys_seen:
    m = KEY_RE.match(lines[keys_seen['log-type']])
    existing_subtype = (m.group(2).strip() if m else '') or None
else:
    set_key('log-type', subtype)
tag_subtype = existing_subtype or subtype
set_key('date', date_stamp)
set_key('timestamp', timestamp)
# R-47 findability tag — add only when tags is absent (survivorship: do not
# rewrite an author-provided tags array).
set_key('tags', f'["#log/{tag_subtype}"]')

new_fm = '\n'.join(lines)
new_content = f'---\n{new_fm}\n---\n{body}'

# Idempotence: if nothing changed (file was already conformant), no write.
if new_content == content:
    sys.exit(0)

tmp_path = file_path + '.autogovern.tmp'
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
