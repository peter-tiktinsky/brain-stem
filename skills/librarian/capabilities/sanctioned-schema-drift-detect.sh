#!/bin/bash
# sanctioned-schema-drift-detect — verify all shipped schemas in the
# live tree match foundation-repo distribution-source.
#
# Defense-in-depth against unsanctioned drift between live ~/.claude/schemas/ and
# foundation-repo schemas/. It checks all shipped schemas (schemas/*.json in the
# foundation-manifest); the fallback pair is plans-schema + plan-manifest-schema
# (vault-schema.json dissolved).
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema appears only as a drift-detection TARGET name (SANCTIONED list); no Draft202012Validator is constructed, so there is no schema-gate degrade path.
# Usage: sanctioned-schema-drift-detect.sh [--json]
#
# BUILD-DOGFOOD-ONLY. This compares the LIVE schemas against the foundation-repo
# distribution SOURCE — a diff that only has meaning where a foundation repo exists
# (the build box). On an adopter install there is NO second copy to diff, so the cap
# CLEAN-SKIPS (rc=0, no findings). An adopter schema TAMPER is a separate, out-of-scope
# concern (a live-hash vs manifest-recorded-hash mechanism), NOT this live-vs-source
# check — the clean-skip is deliberate, not a coverage regression.
#
# Shipped form. The source schema is the development copy, and an install writes the
# cleaned form of it, so a live schema can differ from the source and still be exactly
# what the install shipped. When a live file differs from the source, the installed
# manifest is consulted: a live file whose `shasum -a 256` equals the sha256 that
# manifest records for schemas/<name>.json is the shipped form and is not drift; a live
# file that equals neither the source nor the record is DRIFT (the line then ends "and
# from the installed manifest's recorded sha256"). With no installed manifest, or no
# record for the schema, only the source comparison applies and the output is unchanged.
# The PASS line gains "; K match the shipped form the installed manifest records" only
# when K > 0. --json keeps its shape.
#
# Env overrides:
#   FOUNDATION_REPO   the foundation source repo (default: $HOME/Code/brain-stem);
#                     when its governance/ + schemas/ are absent this is an adopter
#                     install and the cap clean-skips
#   LIVE_SCHEMAS      default: $HOME/.claude/schemas
#   SSDD_INSTALLED_MANIFEST  the installed manifest whose recorded sha256 marks a live
#                     schema as the shipped form (default:
#                     governance/foundation-manifest.json under the parent of LIVE_SCHEMAS,
#                     the governance/ directory that sits beside schemas/)
#
# Exit 0: no drift detected (every sanctioned schema byte-identical to source or equal to
#         the installed manifest's recorded sha256) OR adopter clean-skip (no foundation
#         repo present)
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
shipped_form_count=0
findings=()

# The installed manifest: its recorded sha256 for a schema marks the live file as the
# shipped form. A missing, unreadable or record-less manifest means "no record".
_SSDD_INSTALLED="${SSDD_INSTALLED_MANIFEST:-$(dirname "$LIVE_SCHEMAS")/governance/foundation-manifest.json}"

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
    recorded=""
    if command -v jq >/dev/null 2>&1 && [ -f "$_SSDD_INSTALLED" ]; then
      if ! recorded="$(jq -r --arg p "schemas/$name.json" \
          '[.files[]? | select(.path == $p) | .sha256? | strings] | first // empty' "$_SSDD_INSTALLED" 2>&1)"; then
        recorded=""
      fi
    fi
    live_sha=""
    if [ -n "$recorded" ]; then
      if live_sha="$(shasum -a 256 "$live")"; then live_sha="${live_sha%% *}"; else live_sha=""; fi
    fi
    if [ -n "$recorded" ] && [ "$live_sha" = "$recorded" ]; then
      shipped_form_count=$((shipped_form_count + 1))
    elif [ -n "$recorded" ]; then
      findings+=("DRIFT: $name (live $live differs from source $src and from the installed manifest's recorded sha256)")
      drift_count=$((drift_count + 1))
    else
      findings+=("DRIFT: $name (live $live differs from source $src)")
      drift_count=$((drift_count + 1))
    fi
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
    pass_line="PASS: ${#SANCTIONED[@]}/${#SANCTIONED[@]} sanctioned schemas match foundation-repo source"
    if [[ $shipped_form_count -gt 0 ]]; then
      pass_line="$pass_line; $shipped_form_count match the shipped form the installed manifest records"
    fi
    echo "$pass_line"
  else
    echo "FAIL: $drift_count finding(s):"
    for f in "${findings[@]}"; do
      echo "  - $f"
    done
  fi
fi

[[ $drift_count -eq 0 ]] && exit 0 || exit 1
