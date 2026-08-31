# user-manifest-read.sh — Canonical read API for user-manifest.json fields.
#
# Wraps jq queries with default-fallback semantics so capability shells stop
# encoding `user-manifest.json` field paths inline.
#
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/user-manifest-read.sh"
#   for path in $(umr_get_array '.system.backup_targets'); do ...; done
#   exemptions=$(umr_get_array '.vault.tag_audit_exemptions')
#   aliases_json=$(umr_get_object '.vault.engagement_aliases')
#   transcripts=$(umr_get_string '.vault.transcript_dir')
#
# Consumers (at ship time):
#   - capabilities/backup.sh             (system.backup_targets[])
#   - capabilities/memory-hygiene.sh     (system.memory_hygiene_exemptions[])
#   - capabilities/tag-coverage-audit.sh (vault.tag_audit_exemptions[])
#   - capabilities/placement-validate.sh (vault.logs_whitelist_subdirs[])
#   - capabilities/stale-detect.sh       (vault.logs_whitelist_subdirs[])
#   - capabilities/frontmatter-enforce.sh (vault.engagement_aliases{})
#   - capabilities/transcript-mine.sh    (vault.transcript_dir)
#
# Path resolution order:
#   1. $UMR_USER_MANIFEST_PATH (test/CI override)
#   2. $USER_MANIFEST_PATH (compat with prior consumer convention)
#   3. ${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json
#
# Failure mode (best-effort + diagnostic): missing file / missing field /
# missing jq / parse error → caller-supplied fallback (empty for arrays,
# `{}` for objects, empty string for scalars). JSON `null` collapses to the
# scalar fallback (jq `// ""` semantics). No findings emitted; no non-zero
# exit. Capability wrappers handle graceful-degrade per their own Output
# Contract.
#
# Bash 3.2 clean per R-23.

_umr_resolve_path() {
  printf '%s' "${UMR_USER_MANIFEST_PATH:-${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}}"
}

_umr_readable() {
  local manifest
  manifest=$(_umr_resolve_path)
  [[ -r "$manifest" ]] && command -v jq >/dev/null 2>&1
}

# umr_get_array <jq-path>
# Prints array elements one per line. Empty / missing / error → no output.
umr_get_array() {
  local path="$1"
  if ! _umr_readable; then
    return 0
  fi
  local manifest
  manifest=$(_umr_resolve_path)
  jq -r "${path}[]? // empty" "$manifest" 2>/dev/null
}

# umr_get_object <jq-path>
# Prints object as compact JSON. Missing / error / non-object → "{}".
umr_get_object() {
  local path="$1"
  if ! _umr_readable; then
    printf '%s' '{}'
    return 0
  fi
  local manifest val
  manifest=$(_umr_resolve_path)
  val=$(jq -c "${path} // {}" "$manifest" 2>/dev/null)
  if [[ -z "$val" || "$val" == "null" ]]; then
    printf '%s' '{}'
  else
    printf '%s' "$val"
  fi
}

# umr_get_string <jq-path>
# Prints scalar string value. Missing / null / error / non-string → "".
# jq `// ""` collapses JSON null + missing-key to empty so callers can use
# `[[ -z "$val" ]]` for fallback chaining (see transcript-mine.sh).
umr_get_string() {
  local path="$1"
  if ! _umr_readable; then
    return 0
  fi
  local manifest val
  manifest=$(_umr_resolve_path)
  val=$(jq -r "${path} // \"\"" "$manifest" 2>/dev/null)
  if [[ "$val" == "null" ]]; then
    return 0
  fi
  printf '%s' "$val"
}
