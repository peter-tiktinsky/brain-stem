#!/bin/bash
# capability-registry-parity — Audit capability-registry.json against SKILL.md
# headings + on-disk capability scripts. Mechanical-tier; Monday cron.
# Librarian capability strengthened to enforce disk->registry (a new 5th
# drift class), closing the orphan gap that let unregistered auditors slip
# through. The existing 4 drift classes are PRESERVED.
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
#   (f) every
#       capability with a NON-NULL writes_manifest_subtree must have a body that
#       actually calls manifest_set — converts "the registry can't claim a
#       manifest write the code doesn't do" from fiction-passes-parity into a
#       caught defect (feedback_structural_over_bandaid).
#       -> registry-parity-manifest-write-fiction
#       GATED: the registry's ._parity_pending_manifest_writes[] allowlist names
#       the known-pending fictions; those are emitted ADVISORY (warn) and do NOT
#       count toward TOTAL drift (parity stays non-RED) until each is remediated.
#       A NON-allowlisted non-null-subtree capability missing manifest_set fires
#       HARD (error; counts in TOTAL; turns parity RED).
#   (g) every capability
#       .sh on disk must carry git-INDEX mode 0755 (100755). The git INDEX
#       (git ls-files -s), NOT the worktree `[ -x ]` disk bit, is the SoT — a
#       staged-uncommitted ` M` mode flip (disk 0755, index 100644) is exactly
#       the trap that shipped public v1.1.1's placement-validate.sh DEAD at
#       100644 while every worktree-reading gate stayed GREEN. A capability whose
#       INDEX mode is 100644 ships NON-EXEC → session-close's run_capability can
#       never invoke it → the cap is dead in production.
#       -> registry-parity-cap-index-mode
#       GIT-GATED: when the capabilities dir is not inside a git work tree (an
#       adopter install — no index to read), this class is SKIPPED (no false
#       drift); it is the BUILD-DOGFOOD / ship-gate arm. ship-gate sub-gate 5 +
#       ac-index-mode-parity.sh (T-2) assert the same index-mode truth
#       over the whole manifest-0755 set; this 7th class extends it into the
#       capability registry's own parity audit.
# After T-13 (the 4 engine-auditors absent + parallel-run-audit struck) the
# disk-orphan class reports zero orphans: registered-with-disk == on-disk. This
# is the load-bearing substance's generator<->install ship-list
# parity gate asserts on (R-37-documentary AC CONTRIBUTOR; primary owner).
# Output Contract
#   Files written: findings (NDJSON via hooks/lib/findings.sh) + a markdown
#     summary to stdout.
#   Failure mode: report-only (exit 0; drift findings emitted as JSON;
#     non-zero finding count does NOT change exit). exit 2 only on unknown flag.
# Usage:
#   capability-registry-parity.sh                 # check (default)
#   capability-registry-parity.sh --check         # explicit
#   capability-registry-parity.sh --dry-run       # summary only, no findings
# Env overrides (testing):
#   LIBRARIAN_ROOT_OVERRIDE   relocate librarian/ root for fixture tests
#   FINDINGS_OUTPUT           append findings here instead of stdout
#   EXPECTED_SCHEMA_VERSION   override expected schema_version (default: 1)
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
DRIFT_MANIFEST_FICTION=0
ADVISORY_MANIFEST_FICTION=0
DRIFT_CAP_INDEX_MODE=0
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

# Class (e) NET-NEW: disk->registry orphan check. Every .sh in capabilities/
# (excluding _archive/) must be a registry entry — an on-disk body not in the
# registry is the orphan drift that let the 4 engine-auditors slip through.
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

# Class (f): manifest-write fiction. Every capability with
# a non-null writes_manifest_subtree must have a body that calls manifest_set.
# The registry's ._parity_pending_manifest_writes[] allowlist downgrades the
# known-pending fictions to ADVISORY (warn; not counted in TOTAL) so parity stays
# non-RED until each lands its real write; a NON-allowlisted offender fires HARD.
ALLOWLIST_FILE=$(mktemp -t parity-allowlist-XXXXXX)
jq -r '._parity_pending_manifest_writes // [] | .[]' "$REGISTRY" 2>/dev/null | sort -u > "$ALLOWLIST_FILE"
while IFS=$'\t' read -r name script; do
  [[ -z "$name" ]] && continue
  body="$LIBRARIAN_ROOT/$script"
  # A missing body is already reported by class (b); skip it here.
  [[ -f "$body" ]] || continue
  # Match a real manifest_set INVOCATION, not a mention inside a comment: strip
  # full-line AND inline comments (everything from the first unquoted #-ish marker
  # is coarse but safe here — capability bodies put manifest_set calls on their
  # own command lines), then require `manifest_set` in command position followed
  # by an argument (a quote / dot-path). A documentation mention must NOT satisfy
  # the contract.
  if sed 's/#.*$//' "$body" \
       | grep -qE '(^|[[:space:]]|;|&&|\|\||\|)manifest_set[[:space:]]+['"'"'".$]'; then
    continue
  fi
  if grep -qxF "$name" "$ALLOWLIST_FILE"; then
    # Known-pending fiction — advisory only; does NOT turn parity RED.
    ADVISORY_MANIFEST_FICTION=$((ADVISORY_MANIFEST_FICTION + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-manifest-write-fiction" "$name" \
        "level" "warn" "advisory" "true" \
        "detail" "non-null writes_manifest_subtree but body lacks a manifest_set call (allowlisted pending — T-4 tracked follow-up)"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-manifest-write-fiction (ADVISORY, allowlisted): $name → $script"$'\n'
  else
    # Not allowlisted — hard drift; turns parity RED.
    DRIFT_MANIFEST_FICTION=$((DRIFT_MANIFEST_FICTION + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-manifest-write-fiction" "$name" \
        "level" "error" \
        "detail" "non-null writes_manifest_subtree but body lacks a manifest_set call"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-manifest-write-fiction: $name → $script (declared subtree, body has no manifest_set)"$'\n'
  fi
done < <(jq -r '.capabilities | to_entries[] | select(.value.implementation_status != "spec-only") | select(.value.writes_manifest_subtree != null) | [.key, .value.script] | @tsv' "$REGISTRY")
rm -f "$ALLOWLIST_FILE"

# Class (g): every capability .sh on disk must
# carry git-INDEX mode 100755. The git index (git ls-files -s), NOT the worktree
# `[ -x ]` disk bit, is the SoT — a 100644 index entry ships the cap NON-EXEC even
# when the author's worktree shows 0755 (the trap that shipped v1.1.1's
# placement-validate.sh DEAD). GIT-GATED: skipped on an adopter install with no
# work tree (no index to read → no false drift); it is the build-dogfood arm.
if [[ -d "$CAPABILITIES_DIR" ]] && command -v git >/dev/null 2>&1 \
   && git -C "$CAPABILITIES_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # Enumerate the TRACKED capability .sh bodies via git ls-files -s SCOPED to the
  # capabilities dir, so git itself produces the repo-relative paths — avoiding a
  # string-prefix strip against `rev-parse --show-toplevel`, which on macOS resolves
  # the /var -> /private/var symlink and would never match a /var-rooted find path.
  # Output is `<mode> <sha> <stage>\t<path>`; we only need direct children .sh
  # (maxdepth-1 equivalent: a path with exactly one segment after the dir).
  while IFS= read -r idxline; do
    [[ -z "$idxline" ]] && continue
    imode="${idxline%% *}"
    # ls-files -s -- . from inside the capabilities dir emits paths RELATIVE to it
    # (e.g. `backup.sh`), so a direct-child body has no `/` in its relpath.
    relpath="${idxline#*$'\t'}"
    base="${relpath##*/}"
    case "$base" in *.sh) ;; *) continue ;; esac
    # Direct children only (the registry's disk-orphan class scopes to maxdepth 1).
    case "$relpath" in */*) continue ;; esac
    if [[ "$imode" != "100755" ]]; then
      DRIFT_CAP_INDEX_MODE=$((DRIFT_CAP_INDEX_MODE + 1))
      if [[ "$MODE" != "dry-run" ]]; then
        emit_finding "registry-parity-cap-index-mode" "$base" \
          "level" "error" "index_mode" "$imode" "expected" "100755" \
          "detail" "capability body git-index mode is not 100755 — ships NON-EXEC, run_capability cannot invoke it (the dead-cap class)"
      fi
      REPORT_LINES="${REPORT_LINES}- registry-parity-cap-index-mode: $base (git-index $imode, expected 100755 — ships non-exec)"$'\n'
    fi
  done < <(git -C "$CAPABILITIES_DIR" ls-files -s -- . 2>/dev/null)
fi

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

TOTAL=$((DRIFT_BIJECTION + DRIFT_SCRIPT + DRIFT_SCHEMA_VERSION + DRIFT_SUBTREE_FIELD + DRIFT_DISK_ORPHAN + DRIFT_MANIFEST_FICTION + DRIFT_CAP_INDEX_MODE))
printf "## Capability Registry Parity (%d drift: bijection=%d script=%d schema-version=%d subtree-field=%d disk-orphan=%d manifest-write-fiction=%d cap-index-mode=%d; advisory manifest-write-fiction=%d)\n\n" \
  "$TOTAL" "$DRIFT_BIJECTION" "$DRIFT_SCRIPT" "$DRIFT_SCHEMA_VERSION" "$DRIFT_SUBTREE_FIELD" "$DRIFT_DISK_ORPHAN" "$DRIFT_MANIFEST_FICTION" "$DRIFT_CAP_INDEX_MODE" "$ADVISORY_MANIFEST_FICTION"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- No drift detected."
fi
exit 0
