#!/bin/bash
# backup — Git add/commit/push wrapper across tracked directories.
#
# Manifest-wired: the target list reads
# from `user-manifest.system.backup_targets[]` (schema 1.3.0).
#
# Usage:
#   backup.sh                    # commit + push across default targets
#   backup.sh --dry-run          # show what would be committed; no writes
#   backup.sh --scope <dir>      # restrict to one dir (repeatable via env)
#   backup.sh --message <msg>    # override auto-generated commit message
#
# Default tracked targets (skipped if not a git repo):
#   $VAULT_ROOT          — vault working tree (when present)
#   $CLAUDE_HOME         — config repo
#   $PLANS_DIR           — plans tree
#   plus any paths declared in user-manifest .system.backup_targets[]
#
# Graceful degradation:
#   - Non-repo target: skip silently.
#   - Clean tree: skip with info line.
#   - Push failure: log + report + continue (exit 0).
#
# Env overrides:
#   BACKUP_TARGETS       — colon-separated paths; overrides system defaults.
#   USER_MANIFEST_PATH   — override $CLAUDE_HOME/user-manifest.json source.
#
# Bash 3.2 clean. Never force-pushes, never runs destructive git ops.

set -u
set -o pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_ROOT:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi

DRY_RUN=0
MESSAGE=""
SCOPE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --scope)   SCOPE_OVERRIDE="$2"; shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "backup: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh"; } \
  || source "$_REPO_LIB/user-manifest-read.sh"

# Determine target list.
#
# Resolution order:
#   1. --scope CLI flag (single dir override).
#   2. BACKUP_TARGETS env (colon-separated; overrides defaults entirely).
#   3. System defaults + user-manifest .system.backup_targets[] extensions.
if [[ -n "$SCOPE_OVERRIDE" ]]; then
  TARGETS="$SCOPE_OVERRIDE"
elif [[ -n "${BACKUP_TARGETS:-}" ]]; then
  TARGETS="$BACKUP_TARGETS"
else
  TARGETS=""
  [[ -n "${VAULT_ROOT:-}" ]] && TARGETS="${TARGETS:+$TARGETS:}$VAULT_ROOT"
  TARGETS="${TARGETS:+$TARGETS:}${CLAUDE_HOME:-$HOME/.claude}"
  TARGETS="${TARGETS:+$TARGETS:}${PLANS_DIR:-$HOME/.claude-plans}"
  # User-extension list from manifest (graceful-degrade if missing/jq-absent).
  while IFS= read -r extra_path; do
    [[ -n "$extra_path" ]] && TARGETS="$TARGETS:$extra_path"
  done < <(umr_get_array '.system.backup_targets')
fi

printf "## Backup"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf " (dry-run)"
fi
printf "\n\n"

# Split TARGETS by colon (bash 3.2 safe).
OLD_IFS="$IFS"
IFS=":"
set -- $TARGETS
IFS="$OLD_IFS"

for dir in "$@"; do
  [[ -z "$dir" ]] && continue
  if [[ ! -d "$dir" ]]; then
    printf -- "- %s: not a directory, skipped\n" "$dir"
    continue
  fi
  if [[ ! -d "$dir/.git" ]]; then
    printf -- "- %s: not a git repo, skipped\n" "$dir"
    continue
  fi

  # Check working tree.
  status_output=$(cd "$dir" && git status --porcelain 2>/dev/null || echo "")
  if [[ -z "$status_output" ]]; then
    printf -- "- %s: no changes\n" "$dir"
    continue
  fi

  # Count changed files (excluding vault workspace.json noise).
  change_count=$(echo "$status_output" | wc -l | tr -d ' ')

  # Compose commit message.
  if [[ -n "$MESSAGE" ]]; then
    commit_msg="$MESSAGE"
  else
    commit_msg="librarian: ${change_count} files"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf -- "- %s: %s files would be committed: '%s'\n" \
      "$dir" "$change_count" "$commit_msg"
    # Show first few entries
    echo "$status_output" | head -5 | while IFS= read -r line; do
      printf "    %s\n" "$line"
    done
    if [[ "$change_count" -gt 5 ]]; then
      printf "    ... and %d more\n" $((change_count - 5))
    fi
    continue
  fi

  # Live mode: add + commit + push.
  cd "$dir" || { printf -- "- %s: cd failed\n" "$dir"; continue; }

  # Add all tracked-modified + new files (exclude workspace.json for vault).
  if [[ -n "${VAULT_ROOT:-}" && "$dir" == "$VAULT_ROOT" ]]; then
    # Add selectively — everything except .obsidian/workspace.json.
    git add -A . 2>/dev/null
    git reset -q .obsidian/workspace.json 2>/dev/null || true
  else
    git add -A . 2>/dev/null
  fi

  # Commit (staged may be empty if workspace.json was only change).
  if git diff --cached --quiet 2>/dev/null; then
    printf -- "- %s: no stageable changes after filter\n" "$dir"
    continue
  fi

  if git commit -m "$commit_msg" >/dev/null 2>&1; then
    # Push (best-effort).
    if git push >/dev/null 2>&1; then
      printf -- "- %s: %d files committed, pushed\n" "$dir" "$change_count"
    else
      printf -- "- %s: %d files committed, push failed (reported, not retried)\n" \
        "$dir" "$change_count"
    fi
  else
    printf -- "- %s: commit failed\n" "$dir"
  fi
done

exit 0
