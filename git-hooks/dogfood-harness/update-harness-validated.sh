#!/bin/bash
# update-harness-validated.sh — harness-validated state capability.
#
# Manages plan-tree manifest `harness_validated[]` entries. Verdict-pass
# entries are written by the dogfood-harness post-run; this capability is
# the canonical writer + reader, consumed by:
#   - the dogfood-harness (writes verdict entries via `add`)
#   - foundation-repo post-commit hook (marks stale via `invalidate`)
#   - plans-repo pre-commit hook (queries via `freshness-check`)
#   - librarian audit + librarian session-close (lists via `list`)
#
# Lives in git-hooks/dogfood-harness/ (co-located with verdict-stamper.sh, the
# dogfood-harness seam). Repo-only, author-side, NOT installed.
#
# R-46-cousin gate semantics: the pre-commit hook in plans-repo refuses to
# flip a sub-plan's `top_level_status` from `in_progress` → `complete` unless
# `harness_validated[]` contains an entry where:
#   sub_plan_id matches AND verdict=pass AND sha matches foundation-repo
#   HEAD AND timestamp within last 7 days AND harness_freshness=fresh
#
# Cross-sub-plan invalidation: when foundation-repo HEAD advances past a
# committed scope_paths intersection, the post-commit hook calls
# `invalidate` to mark entries `harness_freshness: invalidated`.
#
# Subcommands:
#   add <plan-manifest-path> <entry-json>   Append verdict entry.
#   list <plan-manifest-path>               Print harness_validated[] (JSON).
#   freshness-check <plan-manifest-path> <sub-plan-id>
#                                           rc=0 if a fresh+pass+matching
#                                           entry exists; rc=1 otherwise.
#                                           --foundation-sha <SHA> required.
#                                           --max-age-days <N> default 7.
#   invalidate <plan-manifest-path> <sub-plan-id>
#                                           Mark all matching entries
#                                           `harness_freshness: invalidated`.
#   query <plan-tree-root>                  Walk all manifests; emit JSONL of
#                                           every harness_validated[] entry
#                                           with computed freshness band.
#
# Exit codes: 0=success; 1=domain failure (e.g., freshness-check no match);
# 2=schema validation failure; 3=I/O / invalid input.

set -uo pipefail

CAP_NAME="update-harness-validated"
SCHEMA_PATH="${PLAN_MANIFEST_SCHEMA:-$HOME/Code/brain-stem/schemas/plan-manifest-schema.json}"
TS_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

err()  { echo "$CAP_NAME: $*" >&2; }
die()  { err "$@"; exit "${2:-3}"; }

usage() {
  sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# === Helper: required-field shape check ===================================
# Schema enforces 14 fields per entry; we ship a defensive tier-1 check on a
# core subset for capability-author UX (faster failure than schema validation
# on full plan manifest).
validate_entry() {
  local entry="$1"
  local missing=()
  for field in harness_id sub_plan_id run_id sha timestamp verdict tier evidence_path harness_freshness schema_version; do
    if ! jq -e --arg f "$field" 'has($f)' <<< "$entry" >/dev/null 2>&1; then
      missing+=("$field")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    err "missing required fields: ${missing[*]}"
    return 2
  fi
  # Verdict + harness_freshness enum check
  local verdict ; verdict=$(jq -r '.verdict' <<< "$entry")
  case "$verdict" in
    pass|fail|partial|skip) ;;
    *) err "invalid verdict: $verdict (expected pass|fail|partial|skip)"; return 2 ;;
  esac
  local fresh ; fresh=$(jq -r '.harness_freshness' <<< "$entry")
  case "$fresh" in
    fresh|stale-7d|stale-30d|invalidated) ;;
    *) err "invalid harness_freshness: $fresh"; return 2 ;;
  esac
  # SHA pattern
  local sha ; sha=$(jq -r '.sha' <<< "$entry")
  if [[ ! "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    err "invalid sha: $sha (expected 7-40 hex chars)"
    return 2
  fi
  return 0
}

# === Helper: atomic JSON file rewrite =====================================
atomic_write() {
  local path="$1" content="$2"
  local tmp ; tmp=$(mktemp "${path}.XXXXXX")
  printf '%s' "$content" > "$tmp"
  mv "$tmp" "$path"
}

# === Helper: compute freshness band for an entry given current HEAD =======
compute_freshness() {
  local entry="$1" current_sha="$2"
  local entry_sha entry_ts now_epoch entry_epoch age_days
  entry_sha=$(jq -r '.sha' <<< "$entry")
  entry_ts=$(jq -r '.timestamp' <<< "$entry")

  # Already-marked invalidated stays invalidated
  if [[ "$(jq -r '.harness_freshness' <<< "$entry")" == "invalidated" ]]; then
    echo "invalidated"; return
  fi

  # SHA-mismatch ⇒ at least stale-7d (cross-sub-plan invalidation
  # discipline; sister sub-plan may have moved scope_paths under us)
  if [[ -n "$current_sha" && "$entry_sha" != "$current_sha" ]]; then
    # SHA mismatch + age >7d ⇒ stale-30d (loose); else stale-7d (tight)
    now_epoch=$(date -u +%s)
    entry_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$entry_ts" +%s 2>/dev/null \
                  || date -d "$entry_ts" +%s 2>/dev/null || echo 0)
    if (( entry_epoch > 0 )); then
      age_days=$(( (now_epoch - entry_epoch) / 86400 ))
      if (( age_days > 30 )); then echo "stale-30d"; return; fi
    fi
    echo "stale-7d"; return
  fi

  # SHA matches: age-only check
  now_epoch=$(date -u +%s)
  entry_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$entry_ts" +%s 2>/dev/null \
                || date -d "$entry_ts" +%s 2>/dev/null || echo 0)
  if (( entry_epoch == 0 )); then echo "invalidated"; return; fi
  age_days=$(( (now_epoch - entry_epoch) / 86400 ))
  if   (( age_days <= 7 )); then echo "fresh"
  elif (( age_days <= 30 )); then echo "stale-7d"
  else echo "stale-30d"
  fi
}

# === Subcommand: add =====================================================
sub_add() {
  local manifest_path="$1" entry_json="$2"
  [[ -f "$manifest_path" ]] || die "manifest not found: $manifest_path"

  validate_entry "$entry_json" || die "entry validation failed" 2

  # Append to harness_validated[] (create if missing)
  local current updated
  current=$(cat "$manifest_path")
  updated=$(jq --argjson entry "$entry_json" \
    '.harness_validated = (.harness_validated // []) + [$entry]' <<< "$current") \
    || die "jq merge failed" 3

  atomic_write "$manifest_path" "$updated"
  err "added entry sub_plan_id=$(jq -r '.sub_plan_id' <<< "$entry_json") to $manifest_path"
}

# === Subcommand: list ====================================================
sub_list() {
  local manifest_path="$1"
  [[ -f "$manifest_path" ]] || die "manifest not found: $manifest_path"
  jq '.harness_validated // []' "$manifest_path"
}

# === Subcommand: freshness-check =========================================
sub_freshness_check() {
  local manifest_path="$1" sub_plan_id="$2" current_sha="" max_age_days=7
  shift 2
  while (( $# > 0 )); do
    case "$1" in
      --foundation-sha) current_sha="$2"; shift 2 ;;
      --max-age-days)   max_age_days="$2"; shift 2 ;;
      *) die "unknown freshness-check arg: $1" 3 ;;
    esac
  done
  [[ -f "$manifest_path" ]] || die "manifest not found: $manifest_path"
  [[ -n "$current_sha" ]] || die "--foundation-sha required" 3

  local entries ; entries=$(jq -c '(.harness_validated // [])[]' "$manifest_path" 2>/dev/null)
  if [[ -z "$entries" ]]; then
    err "no harness_validated[] entries"
    return 1
  fi

  local now_epoch entry_ts entry_epoch age_days
  now_epoch=$(date -u +%s)

  local found=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local sp_match verdict_match sha_match age_match
    sp_match=$(jq -r --arg sp "$sub_plan_id" 'select(.sub_plan_id == $sp) | .sub_plan_id' <<< "$entry")
    [[ -z "$sp_match" ]] && continue
    verdict_match=$(jq -r 'select(.verdict == "pass") | .verdict' <<< "$entry")
    [[ -z "$verdict_match" ]] && continue
    sha_match=$(jq -r --arg sha "$current_sha" 'select(.sha == $sha) | .sha' <<< "$entry")
    [[ -z "$sha_match" ]] && continue
    entry_ts=$(jq -r '.timestamp' <<< "$entry")
    entry_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$entry_ts" +%s 2>/dev/null \
                  || date -d "$entry_ts" +%s 2>/dev/null || echo 0)
    if (( entry_epoch == 0 )); then continue; fi
    age_days=$(( (now_epoch - entry_epoch) / 86400 ))
    if (( age_days <= max_age_days )); then
      # Also require harness_freshness != invalidated (post-commit hook
      # may have flagged this entry stale even if SHA matches; trust the flag)
      local fresh_field ; fresh_field=$(jq -r '.harness_freshness' <<< "$entry")
      if [[ "$fresh_field" == "invalidated" ]]; then continue; fi
      found=1
      break
    fi
  done <<< "$entries"

  if (( found == 1 )); then
    err "freshness-check PASS for $sub_plan_id @ sha=$current_sha"
    return 0
  else
    err "freshness-check FAIL for $sub_plan_id @ sha=$current_sha (no matching fresh+pass entry within ${max_age_days}d)"
    return 1
  fi
}

# === Subcommand: invalidate ==============================================
sub_invalidate() {
  local manifest_path="$1" sub_plan_id="$2"
  [[ -f "$manifest_path" ]] || die "manifest not found: $manifest_path"

  local updated count
  updated=$(jq --arg sp "$sub_plan_id" '
    .harness_validated = (
      (.harness_validated // []) | map(
        if .sub_plan_id == $sp and .harness_freshness != "invalidated" then
          .harness_freshness = "invalidated"
        else . end
      )
    )
  ' "$manifest_path") || die "jq invalidate failed" 3

  count=$(jq --arg sp "$sub_plan_id" \
    '[.harness_validated // [] | .[] | select(.sub_plan_id == $sp and .harness_freshness == "invalidated")] | length' \
    <<< "$updated")

  atomic_write "$manifest_path" "$updated"
  err "invalidated $count entries for sub_plan_id=$sub_plan_id in $manifest_path"
}

# === Subcommand: query ===================================================
sub_query() {
  local plans_root="${1:-$HOME/.claude-plans}"
  [[ -d "$plans_root" ]] || die "plans root not found: $plans_root" 3

  local current_sha=""
  if [[ -d "$HOME/Code/brain-stem/.git" ]]; then
    current_sha=$(git -C "$HOME/Code/brain-stem" rev-parse HEAD 2>/dev/null || echo "")
  fi

  while IFS= read -r manifest; do
    local entries ; entries=$(jq -c '(.harness_validated // [])[]' "$manifest" 2>/dev/null)
    [[ -z "$entries" ]] && continue
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local fresh_band ; fresh_band=$(compute_freshness "$entry" "$current_sha")
      jq -c --arg manifest "$manifest" --arg computed "$fresh_band" \
        '. + {_manifest_path: $manifest, _computed_freshness: $computed}' <<< "$entry"
    done <<< "$entries"
  done < <(find "$plans_root" -maxdepth 4 -name 'manifest.json' -type f 2>/dev/null)
}

# === Main =================================================================
[[ $# -eq 0 ]] && usage

case "$1" in
  add)              shift; sub_add "$@" ;;
  list)             shift; sub_list "$@" ;;
  freshness-check)  shift; sub_freshness_check "$@" ;;
  invalidate)       shift; sub_invalidate "$@" ;;
  query)            shift; sub_query "$@" ;;
  -h|--help|help)   usage ;;
  *) die "unknown subcommand: $1 (expected: add|list|freshness-check|invalidate|query)" 3 ;;
esac
