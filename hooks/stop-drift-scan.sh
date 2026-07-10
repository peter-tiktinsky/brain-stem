#!/bin/bash
# Hook: Stop — Scan touched vault files for frontmatter drift before session exit.
# R-36: Advisory only (dry-run mode). Live enforcement deferred to Phase 4.
# Emits findings to stderr as informational; does NOT block stop (exit 0 always).
set -euo pipefail

# a hardcoded install-path literal. The body sourced the install lib path
# literally, contradicting.14's "5 other C2 hooks portable" estimate;
# the build re-grep is authoritative ([DRIFT] 3).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/registry.sh"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

# per canonical §B; vault-schema.json was dissolved per T-4 pillar shard.
# FOUNDATION_MASTER is resolved by each consumer (not exported by paths.sh);
# the canonical idiom guards against an unbound value under `set -u` on a
# clean install where the bundle is absent.
FOUNDATION_MASTER="${FOUNDATION_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json}"
if [[ ! -f "$FOUNDATION_MASTER" ]]; then
  exit 0
fi
# Canonical governance read: route the schema read through the R-52 union-load
# merger (hooks/lib/foundation-overlay-load.sh) so an adopter's overlay-master.json frontmatter
# amendments are honored — never consume foundation-master RAW. Materialize the merged union
# once and redirect $FOUNDATION_MASTER at it; every downstream `jq ... "$FOUNDATION_MASTER"` is
# unchanged. Degrades to the raw bundle if the merger is unavailable (advisory hook; loud-safe,
# never blocks).
_OVL="${FOUNDATION_OVERLAY_LOAD:-$SCRIPT_DIR/lib/foundation-overlay-load.sh}"
if [[ -x "$_OVL" ]]; then
  _UNION="$(mktemp 2>/dev/null || true)"
  if [[ -n "$_UNION" ]] && bash "$_OVL" --foundation-path "$FOUNDATION_MASTER" \
        --overlay-path "$(dirname "$FOUNDATION_MASTER")/overlay-master.json" --force-override \
        > "$_UNION" 2>/dev/null && [[ -s "$_UNION" ]]; then
    FOUNDATION_MASTER="$_UNION"; trap 'rm -f "$_UNION"' EXIT
  elif [[ -n "$_UNION" ]]; then
    rm -f "$_UNION"
  fi
fi

ensure_coord_dir
REG=$(read_registry)
TOUCHED=$(echo "$REG" | jq -r --arg sid "$SESSION_ID" '(.sessions[$sid].touched_files // []) | .[]' 2>/dev/null || true)

if [[ -z "$TOUCHED" ]]; then
  exit 0
fi

FINDINGS=""
SCANNED=0
ISSUES=0

while IFS= read -r touched; do
  [[ -z "$touched" ]] && continue
  # track-vault-write.sh records an ABSOLUTE file_path in
  # touched_files; the prior FULL="$VAULT_ROOT/$rel_path" double-rooted it (a
  # non-existent path) so the -f guard below skipped EVERY touched file and R-36
  # covered 0. Resolve the absolute path directly; derive the vault-relative form
  # via registry.sh vault_relative() for the .md / Logs-exclusion scope checks and
  # the finding display. A path NOT under VAULT_ROOT yields an empty relative and
  # is skipped (scope preserved). A legacy relative entry keeps the old join.
  if [[ "$touched" == /* ]]; then
    FULL="$touched"
    rel_path="$(vault_relative "$touched")"
    [[ -z "$rel_path" ]] && continue
  else
    rel_path="$touched"
    FULL="$VAULT_ROOT/$rel_path"
  fi

  [[ ! -f "$FULL" ]] && continue
  [[ "$rel_path" != *.md ]] && continue
  [[ "$rel_path" == Logs/.coordination/* ]] && continue

  SCANNED=$((SCANNED + 1))

  FRONTMATTER=""
  IN_FM=false
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if $IN_FM; then
        break
      else
        IN_FM=true
        continue
      fi
    fi
    if $IN_FM; then
      FRONTMATTER="${FRONTMATTER}${line}"$'\n'
    fi
  done < "$FULL"

  if [[ -z "$FRONTMATTER" ]]; then
    FINDINGS="${FINDINGS}  - ${rel_path}: missing frontmatter\n"
    ISSUES=$((ISSUES + 1))
    continue
  fi

  FILE_TYPE=$(echo "$FRONTMATTER" | grep -E '^type:' | head -1 | sed 's/^type:[[:space:]]*//' || true)
  if [[ -z "$FILE_TYPE" ]]; then
    if [[ "$rel_path" != Daily/* ]] && [[ "$rel_path" != Inbox/* ]]; then
      FINDINGS="${FINDINGS}  - ${rel_path}: missing type field\n"
      ISSUES=$((ISSUES + 1))
    fi
    continue
  fi

  SCHEMA_KEY=$(jq -r --arg t "$FILE_TYPE" 'if .frontmatter.types | has($t) then $t else "" end' "$FOUNDATION_MASTER" 2>/dev/null || true)
  if [[ -z "$SCHEMA_KEY" ]]; then
    case "$FILE_TYPE" in
      skill-spec|tier-2) SCHEMA_KEY="reference" ;;
      file-index)        SCHEMA_KEY="index" ;;
      *) ;;
    esac
  fi

  if [[ -z "$SCHEMA_KEY" ]]; then
    FINDINGS="${FINDINGS}  - ${rel_path}: unregistered type '${FILE_TYPE}'\n"
    ISSUES=$((ISSUES + 1))
    continue
  fi

  REQUIRED=$(jq -r --arg k "$SCHEMA_KEY" '.frontmatter.types[$k].required // [] | .[]' "$FOUNDATION_MASTER" 2>/dev/null || true)
  MISSING=""
  for field in $REQUIRED; do
    [[ "$field" == "type" ]] && continue
    if ! echo "$FRONTMATTER" | grep -qE "^${field}:"; then
      MISSING="${MISSING}${field}, "
    fi
  done

  if [[ -n "$MISSING" ]]; then
    MISSING="${MISSING%, }"
    FINDINGS="${FINDINGS}  - ${rel_path}: missing required fields [${MISSING}] for type '${SCHEMA_KEY}'\n"
    ISSUES=$((ISSUES + 1))
  fi
done <<< "$TOUCHED"

if [[ $ISSUES -gt 0 ]]; then
  echo "[R-36 drift-scan] Scanned $SCANNED touched files, found $ISSUES issue(s):" >&2
  echo -e "$FINDINGS" >&2
  journal_emission "Stop" "advise-stop:drift-scan:scanned=$SCANNED:issues=$ISSUES" 0
fi

exit 0
