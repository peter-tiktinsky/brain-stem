#!/usr/bin/env bash
# skills/doc-amender/compose-deterministic.sh — the deterministic persistence
# lane for the doc-amender (persistence.mode=deterministic; NO claude -p).
# source). The doc-amender runtime (skills/doc-amender/process.sh) dispatches to
# this composer when the resolved prompt's persistence_mode is `deterministic`
# (amendment_strategy=template-fill): the deterministic composer fires
# inside the doc-amender launchd lane.
# Two deterministic operations (selected by the prompt's amendment_strategy /
# the contract's pattern_menu):
#   - table-fill  : upsert a row into a markdown table, keyed by the first
#                   column; replace-on-key — an existing-key row is
#                   REPLACED in place; a new-key row is APPENDED.
#   - capped-append (append-section): append the packet body as a section under
#                   a section_key heading, capped to a max number of sections
#                   (oldest sections trimmed). section_key collision:
#                   create-if-absent; if MULTIPLE matching headings already
#                   exist → emit an error sidecar + do NOT compose.
# R-34 boundary: this composer NEVER writes the destination directly. It
# composes the merged body and round-trips it as an amender-replacement packet
# back to staging via hooks/lib/staging-emit.sh (exactly like the LLM lane).
# OUTPUT CONTRACT:
#   Files written: one amender-replacement packet at
#     $STAGING_ROOT/<writer-id>+amender/<sha>.json via staging-emit.sh.
#     On a section_key multi-match collision: an error sidecar
#     <packet>.compose-error.json (NO packet emitted).
#   Pre-write validation: prompt + packet readable; amendment_strategy +
#     section_key/table_key resolved from the contract/prompt (NOT hardcoded);
#     destination-current-content read (empty when destination absent).
#   Failure mode: BLOCK-AND-LOG — missing inputs / unresolvable strategy /
#     collision exit non-zero with a diagnostic; no destination write ever.
# bash 3.2 compatible. jq REQUIRED. shasum REQUIRED (via staging-emit.sh).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
_CD_CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
_CD_STATE_ROOT="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}"

PACKET=""
PROMPT=""
DESTINATION=""
STAGING_EMIT=""
SECTION_CAP=10

usage() {
  cat <<EOF
compose-deterministic.sh — deterministic doc-amender persistence lane (no claude -p).

Usage:
  compose-deterministic.sh --packet <packet.json> --prompt <prompt.md>
                           --destination <path>
                           [--staging-emit <path>] [--section-cap N]

Required:
  --packet         The writer-emit packet whose body is being merged.
  --prompt         The resolved doc-amender-prompt asset (provides
                   amendment_strategy + table_key / section_key frontmatter).
  --destination    The destination path (read for destination_current_content;
                   NEVER written — R-34).

Optional:
  --staging-emit   hooks/lib/staging-emit.sh path (default: installed or repo).
  --section-cap    Max sections kept under capped-append (default 10).

Exit codes:
  0   amender-replacement packet emitted (or no-op when nothing to merge)
  2   bad invocation / missing prereq
  3   pre-flight failure (packet/prompt unreadable; unresolvable strategy)
  4   section_key collision (multiple matching headings) — error sidecar written
  5   staging-emit failure
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --packet)        PACKET="$2"; shift 2 ;;
    --prompt)        PROMPT="$2"; shift 2 ;;
    --destination)   DESTINATION="$2"; shift 2 ;;
    --staging-emit)  STAGING_EMIT="$2"; shift 2 ;;
    --section-cap)   SECTION_CAP="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) printf 'compose-deterministic.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- resolve staging-emit default -------------------------------------------

if [ -z "$STAGING_EMIT" ]; then
  if [ -r "$_CD_CLAUDE_HOME/hooks/lib/staging-emit.sh" ]; then
    STAGING_EMIT="$_CD_CLAUDE_HOME/hooks/lib/staging-emit.sh"
  else
    STAGING_EMIT="$REPO_ROOT/hooks/lib/staging-emit.sh"
  fi
fi

# ---- pre-flight -------------------------------------------------------------

for tool in jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'compose-deterministic.sh: missing prereq: %s\n' "$tool" >&2
    exit 2
  fi
done

if [ -z "$PACKET" ] || [ ! -r "$PACKET" ]; then
  printf 'compose-deterministic.sh: --packet required + readable\n' >&2; exit 3
fi
if [ -z "$PROMPT" ] || [ ! -r "$PROMPT" ]; then
  printf 'compose-deterministic.sh: --prompt required + readable\n' >&2; exit 3
fi
if [ -z "$DESTINATION" ]; then
  printf 'compose-deterministic.sh: --destination required\n' >&2; exit 3
fi
if [ ! -r "$STAGING_EMIT" ]; then
  printf 'compose-deterministic.sh: staging-emit.sh not readable: %s\n' "$STAGING_EMIT" >&2; exit 2
fi
if ! jq empty "$PACKET" >/dev/null 2>&1; then
  printf 'compose-deterministic.sh: packet not valid JSON: %s\n' "$PACKET" >&2; exit 3
fi

# ---- frontmatter reader (line-oriented; from the prompt asset) --------------

fm_value() {
  local file="$1" key="$2"
  grep "^${key}:" "$file" 2>/dev/null | head -1 | sed -e "s/^${key}:[[:space:]]*//" -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

AMENDMENT_STRATEGY=$(fm_value "$PROMPT" "amendment_strategy")
TABLE_KEY=$(fm_value "$PROMPT" "table_key")          # column header used as the upsert key
SECTION_KEY=$(fm_value "$PROMPT" "section_key")      # heading text for capped-append
WRITER_ID=$(jq -r '.writer_id // "doc-amender"' "$PACKET")
SOURCE_ID=$(jq -r '.source_id // empty' "$PACKET")

# The packet body (markdown). For deterministic ops the body is the new content
# to merge (a single table row's worth, or a section's worth).
PACKET_BODY=$(jq -r '.body // ""' "$PACKET")

# Destination current content (read-only — R-34; never written here).
if [ -f "$DESTINATION" ]; then
  DEST_CURRENT=$(cat "$DESTINATION" 2>/dev/null || printf '')
else
  DEST_CURRENT=""
fi

# Resolve the deterministic operation from the strategy (the contract's
# pattern_menu, NOT hardcoded here): template-fill → table-fill;
# append-section → capped-append. Anything else is not a deterministic op.
case "$AMENDMENT_STRATEGY" in
  template-fill)   OP="table-fill" ;;
  append-section)  OP="capped-append" ;;
  *)
    printf 'compose-deterministic.sh: amendment_strategy=%s is not a deterministic op (expected template-fill|append-section)\n' "$AMENDMENT_STRATEGY" >&2
    exit 3
    ;;
esac

# ---- composition via python3 (line-oriented; deterministic; no claude -p) ---
# Python is used for the table-upsert / section-merge string surgery (bash
# line-surgery on markdown tables is error-prone). Inputs passed via argv,
# never a stdin pipe the heredoc would consume. The composer
# emits the MERGED body to a tempfile; the section_key multi-match collision
# is signalled via exit code 4.

MERGED_TMP=$(mktemp -t doc-amender-merged.XXXXXX)

PYRC=0
python3 - "$OP" "$TABLE_KEY" "$SECTION_KEY" "$SECTION_CAP" "$MERGED_TMP" "$PACKET_BODY" "$DEST_CURRENT" <<'PY' || PYRC=$?
import sys, re

op, table_key, section_key, section_cap, merged_tmp, packet_body, dest_current = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]

try:
    section_cap = int(section_cap)
except ValueError:
    section_cap = 10


def table_fill(current, new_row_block, key_col_header):
    """Upsert markdown table rows from new_row_block into current, keyed by the
    first column value (replace-on-key). If current has no table,
    new_row_block is used as the table. Non-table content is preserved as-is."""
    new_rows = [ln for ln in new_row_block.splitlines() if ln.strip().startswith('|')]
    if not new_rows:
        # Nothing table-shaped to merge → append the body verbatim (degenerate).
        sep = '' if current.endswith('\n') or current == '' else '\n'
        return current + sep + new_row_block.rstrip('\n') + '\n'

    def row_key(row):
        cells = [c.strip() for c in row.strip().strip('|').split('|')]
        return cells[0] if cells else ''

    def is_separator(row):
        cells = [c.strip() for c in row.strip().strip('|').split('|')]
        return all(set(c) <= set('-: ') and c != '' for c in cells) if cells else False

    cur_lines = current.splitlines()
    # Locate the existing table region (contiguous run of pipe-rows).
    table_idxs = [i for i, ln in enumerate(cur_lines) if ln.strip().startswith('|')]
    if not table_idxs:
        # No existing table — adopt the new rows as the table, appended.
        sep = '' if current.endswith('\n') or current == '' else '\n'
        return current + sep + '\n'.join(new_rows) + '\n'

    # Index existing data rows by key (skip header + separator).
    existing = {}
    order = []
    header_sep_lines = []
    data_start = None
    seen_data = False
    for i in table_idxs:
        ln = cur_lines[i]
        if not seen_data and (is_separator(ln) or i == table_idxs[0]):
            header_sep_lines.append(i)
            continue
        # First non-header/non-sep pipe row begins data.
        seen_data = True
        if data_start is None:
            data_start = i
        k = row_key(ln)
        if k not in existing:
            order.append(k)
        existing[k] = i

    # Apply upserts.
    for nr in new_rows:
        if is_separator(nr):
            continue
        k = row_key(nr)
        # Skip a re-supplied header row (key == the declared table_key column
        # header), so the packet may carry its own header+separator harmlessly.
        if key_col_header and k == key_col_header:
            continue
        if k in existing:
            cur_lines[existing[k]] = nr          # replace-on-key
        else:
            # Append new-key row at the end of the table region.
            insert_at = table_idxs[-1] + 1
            cur_lines.insert(insert_at, nr)
            table_idxs.append(insert_at)
            existing[k] = insert_at
    return '\n'.join(cur_lines) + ('\n' if current.endswith('\n') else '\n')


def capped_append(current, body, skey, cap):
    """Append `body` as a section under a `## skey` heading. section_key
    collision: create-if-absent; if MULTIPLE `## skey` headings exist
    → signal collision (exit 4)."""
    heading = '## %s' % skey if skey else '## Section'
    if skey:
        matches = [i for i, ln in enumerate(current.splitlines())
                   if ln.strip() == heading]
        if len(matches) > 1:
            return None  # collision → caller exits 4
    sep = '' if current.endswith('\n') or current == '' else '\n'
    new_content = current + sep + heading + '\n' + body.rstrip('\n') + '\n'

    # Cap: keep at most `cap` `## ` sections (trim oldest top-level sections).
    lines = new_content.splitlines()
    sec_starts = [i for i, ln in enumerate(lines) if ln.startswith('## ')]
    if len(sec_starts) > cap:
        drop_count = len(sec_starts) - cap
        cut_at = sec_starts[drop_count]
        preamble = lines[:sec_starts[0]] if sec_starts else lines
        kept = preamble + lines[cut_at:]
        new_content = '\n'.join(kept) + '\n'
    return new_content


if op == 'table-fill':
    merged = table_fill(dest_current, packet_body, table_key)
elif op == 'capped-append':
    merged = capped_append(dest_current, packet_body, section_key, section_cap)
    if merged is None:
        sys.exit(4)  # section_key multi-match collision
else:
    sys.exit(3)

with open(merged_tmp, 'w', encoding='utf-8') as f:
    f.write(merged)
sys.exit(0)
PY

if [ "$PYRC" = "4" ]; then
  rm -f "$MERGED_TMP"
  SIDECAR="${PACKET}.compose-error.json"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reason "section_key-multiple-matches" \
    --arg section_key "$SECTION_KEY" \
    --arg destination "$DESTINATION" \
    '{ts:$ts,reason:$reason,section_key:$section_key,destination_path:$destination,packet_kind:"amender-conflict"}' \
    > "$SIDECAR" 2>/dev/null || true
  printf 'compose-deterministic.sh: section_key=%s has multiple matches at destination; error sidecar written\n' "$SECTION_KEY" >&2
  exit 4
fi
if [ "$PYRC" != "0" ]; then
  rm -f "$MERGED_TMP"
  printf 'compose-deterministic.sh: composition failed (rc=%s)\n' "$PYRC" >&2
  exit 3
fi

# ---- emit the merged body as an amender-replacement packet ------------------
# R-34: round-trip through staging-emit; NEVER write the destination here.

EMIT_WRITER_ID="${WRITER_ID}+amender"
STAGING_EMIT_ARGS=" --writer-id $EMIT_WRITER_ID"
STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --destination-path $DESTINATION"
STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --output-type markdown"
STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --body-file $MERGED_TMP"
STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --packet-kind amender-replacement"
if [ -n "$SOURCE_ID" ]; then
  STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --source-id $SOURCE_ID"
fi

rc=0
# shellcheck disable=SC2086
STAGING_ROOT="${STAGING_ROOT:-$_CD_STATE_ROOT/vault-staging}" \
  bash "$STAGING_EMIT" $STAGING_EMIT_ARGS 2>/dev/null || rc=$?
rm -f "$MERGED_TMP"
if [ "$rc" -ne 0 ]; then
  printf 'compose-deterministic.sh: staging-emit failed rc=%s\n' "$rc" >&2
  exit 5
fi

printf 'compose-deterministic.sh: emitted amender-replacement (op=%s) for %s\n' "$OP" "$DESTINATION" >&2
exit 0
