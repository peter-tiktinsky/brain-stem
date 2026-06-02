#!/bin/bash
# sanctioned-schema-drift-detect — verify the 2 sanctioned schemas in the
# live tree match foundation-repo distribution-source.
#
# Defense-in-depth against unsanctioned drift between
# live ~/.claude/schemas/ and foundation-repo schemas/. Sanctioned schemas
# are plans-schema.json + plan-manifest-schema.json.
#
# Usage: sanctioned-schema-drift-detect.sh [--json]
#
# Env overrides (test-only; production resolves both via the install layout):
#   FOUNDATION_REPO   default: $HOME/Code/brain-stem
#   LIVE_SCHEMAS      default: $HOME/.claude/schemas
#
# Exit 0: no drift detected (all sanctioned schemas byte-identical to source)
# Exit 1: drift detected (writes finding lines to stdout)
# Exit 2: usage / unknown flag

set -euo pipefail

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/brain-stem}"
LIVE_SCHEMAS="${LIVE_SCHEMAS:-$HOME/.claude/schemas}"

SANCTIONED=(plans-schema plan-manifest-schema)

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
