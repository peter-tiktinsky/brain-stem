#!/bin/bash
# log-archive — Archive old log files from the state/logs/ run-log dir per
# retention thresholds (G7,: the rotation home moved off the indexed
# vault Logs/ to the XDG state tier $CLAUDE_LOG_DIR).
# Landed: T-1 (2026-04-21). Extracted from SKILL.md
# `lib/dates.sh` (co-shipped in this commit).
# Thresholds per SKILL.md:
#   - Dashboard-sync logs: older than 3 days
#   - General logs:        older than 7 days
# Target path: $CLAUDE_LOG_DIR/archive/{YYYY}-W{WW}/ where YYYY-WW is ISO
# year+week computed from the filename's leading date.
# CLI:
#   log-archive.sh            # dry-run (default per SKILL.md)
#   log-archive.sh --dry-run  # preview only
#   log-archive.sh --execute  # actually move files
#   log-archive.sh --help     # usage
# Env overrides (testing):
#   LOG_ARCHIVE_SOURCE   — override source dir (default $CLAUDE_LOG_DIR)
#   LOG_ARCHIVE_TARGET   — override archive root (default $CLAUDE_LOG_DIR/archive)
# Scope rules:
#   - Top-level *.md files in $LOG_ARCHIVE_SOURCE only (subdirs preserved).
#   - Symlinks skipped entirely (ideation-brief-*.md symlinks point to
#     ~/.claude-plans/ canonical and must not be moved).
#   - Files with no leading date in the filename are left in place (not
#     archived and not flagged — non-dated content in Logs/ is a
#     placement-validate concern, not a log-archive concern).
#   - Dashboard-sync detection: filename contains "dashboard-sync".
# Bash 3.2 clean per R-23. Never deletes files — only `mv`.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${CLAUDE_LOG_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/dates.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/dates.sh"; } \
  || source "$_REPO_LIB/dates.sh"

MODE="dry-run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "log-archive: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# G7: rotate the XDG state-tier run-log dir, not the indexed vault Logs/.
LOGS_ROOT="${LOG_ARCHIVE_SOURCE:-$CLAUDE_LOG_DIR}"
ARCHIVE_ROOT="${LOG_ARCHIVE_TARGET:-$CLAUDE_LOG_DIR/archive}"
DASHBOARD_THRESHOLD=3
GENERAL_THRESHOLD=7

if [[ ! -d "$LOGS_ROOT" ]]; then
  echo "log-archive: source dir does not exist: $LOGS_ROOT" >&2
  exit 3
fi

archived=0
remaining=0
moved_lines=""
folders_created=""

# Process top-level .md files only. Subdirs (backlog-progress/, foundations-essays/)
# are out of scope per SKILL.md and placement-validate convention.
shopt -s nullglob
for file in "$LOGS_ROOT"/*.md; do
  # Skip symlinks — ideation-brief-*.md are load-bearing symlinks to ~/.claude-plans/.
  if [[ -L "$file" ]]; then
    remaining=$((remaining + 1))
    continue
  fi
  [[ -f "$file" ]] || continue

  fn=$(basename "$file")

  # Extract leading YYYY-MM-DD from filename (anywhere in the name).
  # Matches patterns: "2026-04-21-foo.md", "digest-2026-04-21.md", "foo-2026-04-21-bar.md".
  date=""
  if [[ "$fn" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    date="${BASH_REMATCH[1]}"
  elif [[ "$fn" =~ ([0-9]{4})([0-9]{2})([0-9]{2}) ]]; then
    # session-close emits session-close-YYYYMMDD-
    # HHMMSS.md (%Y%m%d, no dashes), which the dashed-only matcher above skipped
    # -> 20+ session-close logs accumulated unarchivable. Accept the compact
    # %Y%m%d form too and NORMALIZE to dashed so days_since / week_of_year / the
    # year-slice below all receive the YYYY-MM-DD they parse. Matcher-side fix
    # (dashed matched first; the session-close emit is untouched). A malformed
    # 8-digit run normalizes to
    # an invalid date -> days_since returns -1 -> the age<0 guard leaves it.
    date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
  fi

  if [[ -z "$date" ]]; then
    remaining=$((remaining + 1))
    continue
  fi

  age=$(days_since "$date")
  if [[ "$age" -lt 0 ]]; then
    # Malformed date (shouldn't happen after regex match, but defensive).
    remaining=$((remaining + 1))
    continue
  fi

  # Determine threshold
  if [[ "$fn" == *dashboard-sync* ]]; then
    threshold=$DASHBOARD_THRESHOLD
  else
    threshold=$GENERAL_THRESHOLD
  fi

  if [[ "$age" -le "$threshold" ]]; then
    remaining=$((remaining + 1))
    continue
  fi

  year="${date:0:4}"
  week=$(week_of_year "$date")
  target_subdir="${year}-W${week}"
  target_dir="$ARCHIVE_ROOT/$target_subdir"

  if [[ "$MODE" == "execute" ]]; then
    if [[ ! -d "$target_dir" ]]; then
      mkdir -p "$target_dir"
      folders_created="${folders_created}  - logs/archive/${target_subdir}/"$'\n'
    fi
    mv "$file" "$target_dir/"
  else
    # Dry-run — track whether this folder would be created
    if [[ ! -d "$target_dir" ]]; then
      case "$folders_created" in
        *"logs/archive/${target_subdir}/"*) : ;;
        *) folders_created="${folders_created}  - logs/archive/${target_subdir}/"$'\n' ;;
      esac
    fi
  fi

  archived=$((archived + 1))
  moved_lines="${moved_lines}  - ${fn} → logs/archive/${target_subdir}/"$'\n'
done
shopt -u nullglob

# Output per SKILL.md format
prefix=""
if [[ "$MODE" == "dry-run" ]]; then
  prefix="[dry-run] "
fi

printf "## Logs (%d archived, %d remaining) %s\n\n" "$archived" "$remaining" "$prefix"
if [[ "$archived" -gt 0 ]]; then
  printf '%s\n' "- Moved $archived files to logs/archive/"
  if [[ -n "$folders_created" ]]; then
    printf '%s\n%s' "- Created folders:" "$folders_created"
  fi
  if [[ -n "$moved_lines" ]]; then
    printf '%s\n%s' "- Files archived:" "$moved_lines"
  fi
else
  printf '%s\n' "- No files to archive"
fi
printf '%s\n' "- Remaining in logs/: $remaining files (within retention window)"
