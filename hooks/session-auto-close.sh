#!/bin/bash
# Auto session-close: lightweight integrity check + git backup for sessions
# that touched vault files but didn't run /librarian session-close.
# Spawned by session-deregister.sh. Runs detached.
set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"

SESSION_ID="${1:-unknown}"
FILES_LIST_PATH="${2:-}"

# Read touched files from temp file (one per line, handles spaces in names)
TOUCHED_FILES=""
if [[ -n "$FILES_LIST_PATH" ]] && [[ -f "$FILES_LIST_PATH" ]]; then
  TOUCHED_FILES=$(cat "$FILES_LIST_PATH")
  rm -f "$FILES_LIST_PATH"  # Clean up temp file
fi

LOGS_DIR="$VAULT_LOGS"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_STAMP=$(date +"%Y-%m-%d")
LOG_SUFFIX=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOGS_DIR/session-auto-close-${LOG_SUFFIX}.md"

FRONTMATTER_ISSUES=0
BROKEN_LINKS=0
FILES_TOUCHED=0
ISSUES_FOUND=""
FILES_LIST=""
BACKUP_STATUS="skipped"

# --- Step 1: Build touched files list ---
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  FILES_TOUCHED=$((FILES_TOUCHED + 1))
  FULL_PATH="$VAULT_ROOT/$f"
  if [[ -f "$FULL_PATH" ]]; then
    ITEM="- ${f} [modified]"
  else
    ITEM="- ${f} [deleted or moved]"
  fi
  if [[ -z "$FILES_LIST" ]]; then
    FILES_LIST="$ITEM"
  else
    FILES_LIST="${FILES_LIST}\n${ITEM}"
  fi
done <<< "$TOUCHED_FILES"

# --- Step 2: Lightweight integrity checks on .md files ---
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  FULL_PATH="$VAULT_ROOT/$f"
  [[ -f "$FULL_PATH" ]] || continue
  [[ "$f" == *.md ]] || continue

  # Frontmatter validation: check for opening/closing --- delimiters
  FIRST_LINE=$(head -1 "$FULL_PATH")
  if [[ "$FIRST_LINE" == "---" ]]; then
    # Has frontmatter — check for closing delimiter
    FM_CLOSE=$(awk 'NR>1 && /^---$/{found=1; exit} END{print found+0}' "$FULL_PATH")
    if [[ "$FM_CLOSE" != "1" ]]; then
      FRONTMATTER_ISSUES=$((FRONTMATTER_ISSUES + 1))
      ITEM="- ${f}: unclosed frontmatter (missing closing ---)"
      if [[ -z "$ISSUES_FOUND" ]]; then
        ISSUES_FOUND="$ITEM"
      else
        ISSUES_FOUND="${ISSUES_FOUND}\n${ITEM}"
      fi
    fi
  fi

  # Broken wikilink detection: find [[links]] and resolve against filesystem
  WIKILINKS=$(grep -oE '\[\[[^]]+\]\]' "$FULL_PATH" 2>/dev/null || true)
  if [[ -n "$WIKILINKS" ]]; then
    while IFS= read -r link; do
      # Strip [[ and ]], handle aliases (take text before |)
      TARGET=$(echo "$link" | sed 's/^\[\[//;s/\]\]$//;s/|.*//')
      [[ -z "$TARGET" ]] && continue
      # Skip external links and anchors
      [[ "$TARGET" == *"://"* ]] && continue
      [[ "$TARGET" == "#"* ]] && continue

      # Resolve: check if file exists (with or without .md extension)
      RESOLVED=false
      if [[ -f "$VAULT_ROOT/$TARGET" ]] || [[ -f "$VAULT_ROOT/${TARGET}.md" ]]; then
        RESOLVED=true
      fi
      # Also check relative to the file's directory
      FILE_DIR=$(dirname "$FULL_PATH")
      if [[ "$RESOLVED" != "true" ]]; then
        if [[ -f "$FILE_DIR/$TARGET" ]] || [[ -f "$FILE_DIR/${TARGET}.md" ]]; then
          RESOLVED=true
        fi
      fi

      if [[ "$RESOLVED" != "true" ]]; then
        BROKEN_LINKS=$((BROKEN_LINKS + 1))
        ITEM="- ${f}: broken link [[${TARGET}]]"
        if [[ -z "$ISSUES_FOUND" ]]; then
          ISSUES_FOUND="$ITEM"
        else
          ISSUES_FOUND="${ISSUES_FOUND}\n${ITEM}"
        fi
      fi
    done <<< "$WIKILINKS"
  fi
done <<< "$TOUCHED_FILES"

# --- Step 3: Git backup ---
if command -v git &>/dev/null && [[ -d "$VAULT_ROOT/.git" ]]; then
  cd "$VAULT_ROOT"
  # Stage touched files that exist
  STAGED=false
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -f "$VAULT_ROOT/$f" ]]; then
      git add "$f" 2>/dev/null && STAGED=true
    fi
  done <<< "$TOUCHED_FILES"

  if [[ "$STAGED" == "true" ]]; then
    # Only commit if there are staged changes
    if ! git diff --cached --quiet 2>/dev/null; then
      git commit -m "auto-close: ${SESSION_ID:0:8}" --no-gpg-sign 2>/dev/null && BACKUP_STATUS="success" || BACKUP_STATUS="error"
    else
      BACKUP_STATUS="no-changes"
    fi
  else
    BACKUP_STATUS="no-changes"
  fi
fi

# --- Step 4: Write log ---
mkdir -p "$LOGS_DIR"

ISSUES_SECTION=""
if [[ -n "$ISSUES_FOUND" ]]; then
  ISSUES_SECTION="## Issues Found
$(echo -e "$ISSUES_FOUND")"
else
  ISSUES_SECTION="## Issues Found
None."
fi

cat > "$LOG_FILE" << LOGEOF
---
type: log
log-type: session-auto-close
date: ${DATE_STAMP}
timestamp: ${TIMESTAMP}
session-id: ${SESSION_ID}
files-touched: ${FILES_TOUCHED}
frontmatter-issues: ${FRONTMATTER_ISSUES}
broken-links: ${BROKEN_LINKS}
backup-status: ${BACKUP_STATUS}
tags: ["#log/session-auto-close"]
---

## Auto-Close Summary
Session ended without explicit /librarian session-close.
Lightweight integrity check and backup performed automatically.

## Touched Files
$(echo -e "$FILES_LIST")

$(echo -e "$ISSUES_SECTION")

## Note
This was an auto-close, not a full session-close. For complete integrity
checking (sync-check, placement-validate, stale-detect, manifest regen),
run /librarian session-close explicitly before ending sessions.
LOGEOF

exit 0
