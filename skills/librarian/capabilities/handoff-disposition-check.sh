#!/bin/bash
# handoff-disposition-check — Block session-close when touched handoff.md
# files contain unresolved follow-up language without a disposition tag.
#
# Enforcement layer for R-25.
#
# Usage:
#   handoff-disposition-check.sh --files <file> [--files <file> ...]
#   echo "<file>" | handoff-disposition-check.sh            # stdin scope
#
# Unresolved-language regex (case-insensitive):
#   (^|[^a-z])(should|later|eventually|TODO|worth watching|flagged|follow[- ]?up)([^a-z]|$)
#
# Disposition tags (same line, or within the next 2 lines — SCOPED PER-ITEM: the
# lookahead is TRUNCATED at the first subsequent line that is itself a hit-line or
# starts a new bullet/list item, so a disposition belonging to the NEXT item can
# no longer satisfy this hit):
#   FIX NOW | ABSORB | STANDALONE | deferred-to:<slug>
#
# Emits blocking finding 'handoff-disposition-missing' per unresolved hit.
#
# Env overrides: FINDINGS_OUTPUT.
# Bash 3.2 clean per R-23.

set -u
set -o pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"

FILES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --files) FILES="${FILES}${2}"$'\n'; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "handoff-disposition-check: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Stdin fallback if no --files provided.
if [[ -z "$FILES" ]] && [[ ! -t 0 ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    FILES="${FILES}${line}"$'\n'
  done
fi

if [[ -z "$FILES" ]]; then
  echo "## Handoff Dispositions (0 missing)"
  echo ""
  echo "- No handoff.md files in scope."
  exit 0
fi

MISSING=0
REPORT_LINES=""

# For each file, scan line by line.
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  # Only process *handoff.md
  case "$(basename "$file")" in
    *handoff.md) ;;
    *) continue ;;
  esac
  if [[ ! -f "$file" ]]; then
    continue
  fi

  # Use Python for precise regex + 2-line-window scan (bash 3.2 grep variants
  # can't cleanly do word-boundary + case-insensitive + N-lookahead).
  RESULT=$(python3 - "$file" <<'PY'
import re, sys
path = sys.argv[1]
# Word-boundary-guarded unresolved-language regex per SKILL.md.
hit_re = re.compile(
    r"(^|[^a-zA-Z])(should|later|eventually|TODO|worth watching|flagged|follow[- ]?up)([^a-zA-Z]|$)",
    re.IGNORECASE,
)
disp_re = re.compile(
    r"\b(FIX NOW|ABSORB|STANDALONE|deferred[- ]to:)",
    re.IGNORECASE,
)
# A new bullet / ordered-list item starts a new logical item — the per-item
# disposition-window boundary.
item_re = re.compile(r"^\s*([-*+]|\d+[.)])\s")
try:
    with open(path) as f:
        lines = f.readlines()
except Exception:
    sys.exit(0)
for i, line in enumerate(lines):
    m = hit_re.search(line)
    if not m:
        continue
    # Per-item disposition window: the hit's OWN line plus up to 2 lookahead
    # lines, TRUNCATED at the first subsequent line that is itself a
    # hit-line or starts a new bullet/list item — a disposition beyond that
    # boundary belongs to the NEXT item and must not satisfy this hit. R-25's
    # "same line or within the next 2 lines" contract holds for the single-item
    # case; only the cross-item bleed is closed.
    window_lines = [line]
    for j in range(i + 1, min(i + 3, len(lines))):
        nxt = lines[j]
        if hit_re.search(nxt) or item_re.match(nxt):
            break
        window_lines.append(nxt)
    window = "".join(window_lines)
    if disp_re.search(window):
        continue
    # Emit one record per missing-disposition hit.
    phrase = m.group(2).strip()
    trimmed = line.strip().replace('"', '\\"')
    print(f"{i+1}\t{phrase}\t{trimmed}")
PY
)

  if [[ -z "$RESULT" ]]; then
    continue
  fi

  while IFS=$'\t' read -r lineno phrase matched; do
    [[ -z "$lineno" ]] && continue
    MISSING=$((MISSING + 1))
    emit_finding "handoff-disposition-missing" "$file" \
      "line" "$lineno" \
      "phrase" "$phrase" \
      "matched" "$matched" \
      "level" "error"
    REPORT_LINES="${REPORT_LINES}- ${file}:${lineno} — \"${phrase}\" needs one of FIX NOW / ABSORB / STANDALONE / deferred-to:"$'\n'
  done <<< "$RESULT"
done <<< "$FILES"

printf "## Handoff Dispositions (%d missing)\n\n" "$MISSING"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- All unresolved language disposed."
fi

# Non-zero exit if missing — session-close contract blocks on this.
if [[ "$MISSING" -gt 0 ]]; then
  exit 1
fi
exit 0
