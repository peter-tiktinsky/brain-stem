#!/bin/bash
# sanctioned-schema-drift-detect — verify all shipped schemas in the
# live tree match foundation-repo distribution-source.
#
# Defense-in-depth against unsanctioned drift between live ~/.claude/schemas/ and
# foundation-repo schemas/. It checks all shipped schemas (schemas/*.json in the
# foundation-manifest); the fallback pair is plans-schema + plan-manifest-schema
# (vault-schema.json dissolved).
#
# Usage: sanctioned-schema-drift-detect.sh [--json]
#
# BUILD-DOGFOOD-ONLY. This compares the LIVE schemas against the foundation-repo
# distribution SOURCE — a diff that only has meaning where a foundation repo exists
# (the build box). On an adopter install there is NO second copy to diff, so the cap
# CLEAN-SKIPS (rc=0, no findings). An adopter schema TAMPER is a separate, out-of-scope
# concern (a live-hash vs manifest-recorded-hash mechanism), NOT this live-vs-source
# check — the clean-skip is deliberate, not a coverage regression.
#
# Env overrides:
#   FOUNDATION_REPO   the foundation source repo (default: $HOME/Code/brain-stem);
#                     when its governance/ + schemas/ are absent this is an adopter
#                     install and the cap clean-skips
#   LIVE_SCHEMAS      default: $HOME/.claude/schemas
#
# Exit 0: no drift detected (all sanctioned schemas byte-identical to source) OR
#         adopter clean-skip (no foundation repo present)
# Exit 1: drift detected (writes finding lines to stdout)
# Exit 2: usage / unknown flag

set -euo pipefail

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/brain-stem}"
LIVE_SCHEMAS="${LIVE_SCHEMAS:-$HOME/.claude/schemas}"

# DERIVE SANCTIONED from the shipped schema set
# (foundation-manifest.json .files[] schemas/*.json) rather than a 2-entry hardcode — the other
# 11+ shipped schemas were unguarded (type-table-ceiling). A live/source byte-divergence on ANY
# shipped schema now emits DRIFT. Falls back to the original 2-entry list when the manifest is
# unreadable (loud-safe; the 2 originals always gate).
SANCTIONED=()
_SSDD_MANIFEST="${SSDD_MANIFEST:-$FOUNDATION_REPO/governance/foundation-manifest.json}"
if command -v jq >/dev/null 2>&1 && [ -f "$_SSDD_MANIFEST" ]; then
  while IFS= read -r _s; do
    [ -n "$_s" ] && SANCTIONED+=("$_s")
  done < <(jq -r '.files[].path | select(startswith("schemas/") and endswith(".json")) | sub("^schemas/";"") | sub("\\.json$";"")' "$_SSDD_MANIFEST" 2>/dev/null || true)
fi
if [ "${#SANCTIONED[@]}" -eq 0 ]; then
  SANCTIONED=(plans-schema plan-manifest-schema)
fi

JSON_MODE=false
for arg in "$@"; do
  case "$arg" in
    --json) JSON_MODE=true ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Build-dogfood gate (mirrors governance-parity-audit's is_build_dogfood): the
# live-vs-source diff only has meaning where a foundation repo exists. On an adopter
# install (no foundation repo) there is no distribution SOURCE to diff against, so a
# live-vs-source check is meaningless and every schema would false-report
# MISSING-SOURCE. Clean-skip rc=0 with NO findings — a DELIBERATE adopter skip, not a
# coverage regression (adopter schema tamper = a separate manifest-hash mechanism).
if [ ! -d "$FOUNDATION_REPO/governance" ] || [ ! -d "$FOUNDATION_REPO/schemas" ]; then
  if [[ "$JSON_MODE" == "true" ]]; then
    printf '{"drift_count":0,"findings":[],"skipped":"adopter-no-foundation-repo"}\n'
  else
    echo "SKIP: no foundation repo at $FOUNDATION_REPO (adopter install) — build-dogfood-only ship-integrity check, clean-skip (rc=0, 0 findings)"
  fi
  exit 0
fi

drift_count=0
findings=()

for name in "${SANCTIONED[@]}"; do
  live="$LIVE_SCHEMAS/$name.json"
  src="$FOUNDATION_REPO/schemas/$name.json"
  if [[ ! -f "$live" ]]; then
    findings+=("MISSING-LIVE: $live")
    drift_count=$((drift_count + 1))
    continue
  fi
  if [[ ! -f "$src" ]]; then
    findings+=("MISSING-SOURCE: $src")
    drift_count=$((drift_count + 1))
    continue
  fi
  if ! diff -q "$live" "$src" >/dev/null 2>&1; then
    findings+=("DRIFT: $name (live $live differs from source $src)")
    drift_count=$((drift_count + 1))
  fi
done

if [[ "$JSON_MODE" == "true" ]]; then
  printf '{"drift_count":%d,"findings":[' "$drift_count"
  first=true
  if [[ ${#findings[@]} -gt 0 ]]; then
    for f in "${findings[@]}"; do
      if $first; then first=false; else printf ','; fi
      esc=${f//\\/\\\\}
      esc=${esc//\"/\\\"}
      printf '"%s"' "$esc"
    done
  fi
  printf ']}\n'
else
  if [[ $drift_count -eq 0 ]]; then
    echo "PASS: ${#SANCTIONED[@]}/${#SANCTIONED[@]} sanctioned schemas match foundation-repo source"
  else
    echo "FAIL: $drift_count finding(s):"
    for f in "${findings[@]}"; do
      echo "  - $f"
    done
  fi
fi

[[ $drift_count -eq 0 ]] && exit 0 || exit 1
