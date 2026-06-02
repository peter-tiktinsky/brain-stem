#!/bin/bash
# capability-registry-parity — Audit capability-registry.json against SKILL.md
# headings + on-disk capability scripts. Mechanical-tier; Monday cron.
#
# Librarian capability that enforces
# disk->registry (the 5th drift class), closing the orphan gap.
# The existing 4 drift classes are PRESERVED.
#
# Audits 5 drift classes:
#   (a) SKILL.md `## Capability: <name>` headings <-> registry keys (strict bijection)
#       -> registry-parity-bijection-drift
#   (b) Every shipped entry's `script` field points to an existing file
#       (spec-only / contract-reserved entries excluded — documented stubs)
#       -> registry-parity-script-missing
#   (c) Registry `schema_version` matches the expected value (1)
#       -> registry-parity-schema-version-drift
#   (d) Every capability with `emits_findings: true` declares
#       `writes_manifest_subtree` (string or null — key MUST be present)
#       -> registry-parity-emits-missing-subtree-field
#   (e) every .sh in capabilities/ is a
#       registry entry — an orphan .sh on disk not in the registry is drift
#       -> registry-parity-disk-orphan
#       (spec-only registry entries are NOT required to have a disk body; the
#       orphan check is the converse: disk bodies must be registered.)
#
# The disk-orphan class reports zero orphans when registered-with-disk == on-disk.
# This is the load-bearing substance the generator<->install ship-list
# parity gate asserts on (R-37-documentary AC contributor).
#
# Output Contract
#   Files written: findings (NDJSON via hooks/lib/findings.sh) + a markdown
#     summary to stdout.
#   Failure mode: report-only (exit 0; drift findings emitted as JSON;
#     non-zero finding count does NOT change exit). exit 2 only on unknown flag.
#
# Usage:
#   capability-registry-parity.sh                 # check (default)
#   capability-registry-parity.sh --check         # explicit
#   capability-registry-parity.sh --dry-run       # summary only, no findings
#
# Env overrides (testing):
#   LIBRARIAN_ROOT_OVERRIDE   relocate librarian/ root for fixture tests
#   FINDINGS_OUTPUT           append findings here instead of stdout
#   EXPECTED_SCHEMA_VERSION   override expected schema_version (default: 1)
#
# Bash 3.2 clean per R-23.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRARIAN_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIAN_ROOT="${LIBRARIAN_ROOT_OVERRIDE:-$LIBRARIAN_ROOT_DEFAULT}"

REGISTRY="$LIBRARIAN_ROOT/capability-registry.json"
SKILL_MD="$LIBRARIAN_ROOT/SKILL.md"
CAPABILITIES_DIR="$LIBRARIAN_ROOT/capabilities"

EXPECTED_SCHEMA_VERSION="${EXPECTED_SCHEMA_VERSION:-1}"

# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$LIBRARIAN_ROOT/../.." && pwd)/hooks/lib/findings.sh"

MODE="check"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   MODE="check"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "capability-registry-parity: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$REGISTRY" ]]; then
  echo "## Capability Registry Parity (skipped)"
  echo ""
  echo "- registry not found: $REGISTRY"
  exit 0
fi

if ! jq empty "$REGISTRY" >/dev/null 2>&1; then
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-invalid-json" "$REGISTRY" \
      "level" "error" "detail" "jq parse failed"
  fi
  echo "## Capability Registry Parity (1 drift)"
  echo ""
  echo "- registry-parity-invalid-json: $REGISTRY"
  exit 0
fi

DRIFT_BIJECTION=0
DRIFT_SCRIPT=0
DRIFT_SCHEMA_VERSION=0
DRIFT_SUBTREE_FIELD=0
DRIFT_DISK_ORPHAN=0
REPORT_LINES=""

# Class (c): schema_version drift
ACTUAL_SCHEMA=$(jq -r '.schema_version // "missing"' "$REGISTRY")
if [[ "$ACTUAL_SCHEMA" != "$EXPECTED_SCHEMA_VERSION" ]]; then
  DRIFT_SCHEMA_VERSION=$((DRIFT_SCHEMA_VERSION + 1))
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-schema-version-drift" "$REGISTRY" \
      "level" "error" "expected" "$EXPECTED_SCHEMA_VERSION" "actual" "$ACTUAL_SCHEMA"
  fi
  REPORT_LINES="${REPORT_LINES}- registry-parity-schema-version-drift: expected=$EXPECTED_SCHEMA_VERSION actual=$ACTUAL_SCHEMA"$'\n'
fi

# Class (b): script-missing on non-spec-only entries
while IFS=$'\t' read -r name script; do
  [[ -z "$name" ]] && continue
  if [[ ! -f "$LIBRARIAN_ROOT/$script" ]]; then
    DRIFT_SCRIPT=$((DRIFT_SCRIPT + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-script-missing" "$name" \
        "level" "error" "script" "$script" "expected_path" "$LIBRARIAN_ROOT/$script"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-script-missing: $name → $script"$'\n'
  fi
done < <(jq -r '.capabilities | to_entries[] | select(.value.implementation_status != "spec-only") | [.key, .value.script] | @tsv' "$REGISTRY")

# Class (d): emits_findings without writes_manifest_subtree key
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  DRIFT_SUBTREE_FIELD=$((DRIFT_SUBTREE_FIELD + 1))
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-emits-missing-subtree-field" "$name" \
      "level" "error" "detail" "emits_findings:true but writes_manifest_subtree key absent"
  fi
  REPORT_LINES="${REPORT_LINES}- registry-parity-emits-missing-subtree-field: $name"$'\n'
done < <(jq -r '.capabilities | to_entries[] | select(.value.emits_findings == true) | select(.value | has("writes_manifest_subtree") | not) | .key' "$REGISTRY")

# Class (e): disk->registry orphan check. Every .sh in capabilities/
# (excluding _archive/) must be a registry entry — an on-disk body not in the
# registry is orphan drift.
REG_SCRIPTS_FILE=$(mktemp -t reg-scripts-XXXXXX)
jq -r '.capabilities | to_entries[] | .value.script' "$REGISTRY" 2>/dev/null \
  | sed 's#^capabilities/##' | sort -u > "$REG_SCRIPTS_FILE"
if [[ -d "$CAPABILITIES_DIR" ]]; then
  while IFS= read -r diskfile; do
    base="$(basename "$diskfile")"
    if ! grep -qxF "$base" "$REG_SCRIPTS_FILE"; then
      DRIFT_DISK_ORPHAN=$((DRIFT_DISK_ORPHAN + 1))
      if [[ "$MODE" != "dry-run" ]]; then
        emit_finding "registry-parity-disk-orphan" "$base" \
          "level" "error" "detail" "capabilities/.sh on disk not registered in capability-registry.json"
      fi
      REPORT_LINES="${REPORT_LINES}- registry-parity-disk-orphan: $base (on disk, not in registry)"$'\n'
    fi
  done < <(find "$CAPABILITIES_DIR" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)
fi
rm -f "$REG_SCRIPTS_FILE"

# Class (a): SKILL.md <-> registry strict bijection
if [[ ! -f "$SKILL_MD" ]]; then
  DRIFT_BIJECTION=$((DRIFT_BIJECTION + 1))
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-skill-md-missing" "$SKILL_MD" "level" "error"
  fi
  REPORT_LINES="${REPORT_LINES}- registry-parity-skill-md-missing: $SKILL_MD"$'\n'
else
  REG_KEYS_FILE=$(mktemp -t reg-keys-XXXXXX)
  SKILL_KEYS_FILE=$(mktemp -t skill-keys-XXXXXX)
  jq -r '.capabilities | keys[]' "$REGISTRY" | sort -u > "$REG_KEYS_FILE"
  grep -E "^## Capability: " "$SKILL_MD" | sed 's/^## Capability: //' | sort -u > "$SKILL_KEYS_FILE"
  while IFS= read -r heading; do
    [[ -z "$heading" ]] && continue
    DRIFT_BIJECTION=$((DRIFT_BIJECTION + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-bijection-drift" "$heading" \
        "level" "error" "direction" "skill-md-without-registry-entry"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-bijection-drift: $heading (SKILL.md heading without registry entry)"$'\n'
  done < <(comm -23 "$SKILL_KEYS_FILE" "$REG_KEYS_FILE")
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    DRIFT_BIJECTION=$((DRIFT_BIJECTION + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-bijection-drift" "$key" \
        "level" "error" "direction" "registry-entry-without-skill-md-heading"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-bijection-drift: $key (registry entry without SKILL.md heading)"$'\n'
  done < <(comm -13 "$SKILL_KEYS_FILE" "$REG_KEYS_FILE")
  rm -f "$REG_KEYS_FILE" "$SKILL_KEYS_FILE"
fi

TOTAL=$((DRIFT_BIJECTION + DRIFT_SCRIPT + DRIFT_SCHEMA_VERSION + DRIFT_SUBTREE_FIELD + DRIFT_DISK_ORPHAN))
printf "## Capability Registry Parity (%d drift: bijection=%d script=%d schema-version=%d subtree-field=%d disk-orphan=%d)\n\n" \
  "$TOTAL" "$DRIFT_BIJECTION" "$DRIFT_SCRIPT" "$DRIFT_SCHEMA_VERSION" "$DRIFT_SUBTREE_FIELD" "$DRIFT_DISK_ORPHAN"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- No drift detected."
fi
exit 0
