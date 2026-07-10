#!/bin/bash
# capability-registry-parity — Audit capability-registry.json against SKILL.md
# headings + on-disk capability scripts. Mechanical-tier; Monday cron.
#
# Enforces BOTH directions of registry<->reality parity, including the
# disk->registry orphan direction that closed the gap letting unregistered
# auditors slip through.
#
# Audits the drift classes enumerated below — the lettered list IS the roster
# (deliberately not counted: a literal count re-opens the/
# self-count-drift class; ac-governance-self-count-consistency.sh gates it):
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
#       over the whole manifest-0755 set; this class extends it into the
#       capability registry's own parity audit.
#   (h) the SKILL.md `### What full runs` backtick-roster set must EQUAL the
#       registry `librarian-full` set ({cap : 'librarian-full' in
#       invocation_modes}) — a strict bijection on the `full` cron roster.
#       -> registry-parity-full-roster-drift
#       Emits on BOTH directions: direction=missing-from-prose (a librarian-full
#       cap absent from the SKILL roster) and direction=extra-in-prose (a SKILL
#       roster name not librarian-full in the registry). HARD/RED (level error;
#       counted in TOTAL; turns parity RED) mirroring class (a) — the `### What
#       full runs` prose is a shipped-doc-correctness surface, not advisory. The
#       cron dispatch itself is registry-driven; this class gates the DOC snapshot
#       from drifting from the authoritative roster.
#
# After T-13 (the 4 engine-auditors absent + parallel-run-audit struck) the
# disk-orphan class reports zero orphans: registered-with-disk == on-disk. This
# is the load-bearing substance's generator<->install ship-list
# parity gate asserts on (R-37-documentary AC CONTRIBUTOR; primary owner).
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

# the govern skill's executable modes/ inventory (a capability-like
# surface with NO registry) audited for disk<->declaration bijection. GOVERN_ROOT_OVERRIDE for
# fixture tests; else the sibling skills/govern/ (one level up from LIBRARIAN_ROOT).
GOVERN_ROOT="${GOVERN_ROOT_OVERRIDE:-$(cd "$LIBRARIAN_ROOT/../govern" 2>/dev/null && pwd)}"

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
DRIFT_FULL_ROSTER=0
DRIFT_GOVERN_MODES=0
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

# Class (h): SKILL.md `### What full runs` roster <-> registry librarian-full set.
# The `### What full runs` backtick-roster is a shipped-doc snapshot of the cron
# `full` roster; it must EQUAL {cap : 'librarian-full' in invocation_modes}. Only
# run when the SKILL.md is present (class (a) reports its absence otherwise).
if [[ -f "$SKILL_MD" ]]; then
  # Region-scoped extraction (argv-Python, R-24): the roster set is the backtick-
  # wrapped tokens INSIDE the `### What full runs` region ONLY (from that heading up
  # to the next `### `/`## `/`---` boundary) — NOT the whole file's backticks. The
  # registry set is the librarian-full members. Both printed sorted, tab-separated
  # as `<direction>\t<name>` mismatch rows (missing-from-prose / extra-in-prose).
  FULL_ROSTER_DRIFT_FILE=$(mktemp -t full-roster-XXXXXX)
  python3 - "$SKILL_MD" "$REGISTRY" > "$FULL_ROSTER_DRIFT_FILE" <<'PY'
import json, re, sys
skill_md, registry = sys.argv[1], sys.argv[2]

# --- SKILL.md `### What full runs` region roster set -----------------------------
try:
    with open(skill_md, encoding="utf-8") as fh:
        text = fh.read()
except Exception:
    sys.exit(0)  # unreadable SKILL.md — class (a) already covers its absence
lines = text.splitlines()
in_region = False
roster_lines = []
for ln in lines:
    if ln.startswith("### ") and "What" in ln and "full" in ln and "runs" in ln:
        in_region = True
        continue
    if in_region:
        # region ends at the next section heading or a horizontal rule
        if ln.startswith("### ") or ln.startswith("## ") or ln.strip() == "---":
            break
        # The ROSTER is the `> `-blockquote block ONLY — not the surrounding intro
        # prose (which backticks `full` / `librarian-full` / `invocation_modes`) nor
        # the trailing "NOT every capability" prose (which backticks the per-plan /
        # non-full caps). Scope token extraction to the blockquote lines.
        if ln.lstrip().startswith(">"):
            roster_lines.append(ln)
roster_text = "\n".join(roster_lines)
# Backtick-wrapped tokens inside the blockquote roster. A cap name is [a-z0-9-]+.
roster = set(re.findall(r"`([a-z0-9][a-z0-9-]*)`", roster_text))

# --- registry librarian-full set -------------------------------------------------
try:
    with open(registry, encoding="utf-8") as fh:
        reg = json.load(fh)
except Exception:
    sys.exit(0)
caps = reg.get("capabilities", {})
full = set(
    k for k, v in caps.items()
    if isinstance(v, dict) and "librarian-full" in (v.get("invocation_modes") or [])
)

for name in sorted(full - roster):
    print("missing-from-prose\t%s" % name)   # a librarian-full cap absent from the SKILL roster
for name in sorted(roster - full):
    print("extra-in-prose\t%s" % name)        # a SKILL roster name not librarian-full in the registry
PY
  while IFS=$'\t' read -r direction name; do
    [[ -z "$name" ]] && continue
    DRIFT_FULL_ROSTER=$((DRIFT_FULL_ROSTER + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-full-roster-drift" "$name" \
        "level" "error" "direction" "$direction" \
        "detail" "SKILL.md '### What full runs' roster != registry librarian-full set"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-full-roster-drift: $name ($direction)"$'\n'
  done < "$FULL_ROSTER_DRIFT_FILE"
  rm -f "$FULL_ROSTER_DRIFT_FILE"
fi

# govern-modes parity — the disk<->declaration bijection for the
# govern skill's executable modes/. Each skills/govern/modes/*.sh must be a declared --kind in
# process.sh's `case "$KIND" in` dispatcher (which sources MODES_DIR/$KIND.sh), and every
# declared --kind must have a modes/<kind>.sh. An undeclared mode .sh OR a declared-but-absent
# mode emits govern-modes-drift, in BOTH directions. Was: govern modes/ entirely unaudited
# (LIBRARIAN_ROOT-scoped only). The librarian classes a-h above are UNCHANGED.
GOVERN_PROCESS="$GOVERN_ROOT/process.sh"
GOVERN_MODES_DIR="$GOVERN_ROOT/modes"
if [[ -n "$GOVERN_ROOT" && -f "$GOVERN_PROCESS" && -d "$GOVERN_MODES_DIR" ]]; then
  # Declared modes: the KIND case-arm (the pipe-separated valid kinds ending in `)`), extracted
  # from the first arm line after `case "$KIND" in`.
  GM_DECLARED_RAW="$(awk '/case[[:space:]]+"\$KIND"[[:space:]]+in/{f=1;next} f&&/\)/{print;exit}' "$GOVERN_PROCESS")"
  GM_DECLARED="$(printf '%s' "$GM_DECLARED_RAW" | tr -d '[:space:]' | sed 's/).*$//')"
  GM_DECL_FILE="$(mktemp -t gm-decl-XXXXXX)"
  GM_DISK_FILE="$(mktemp -t gm-disk-XXXXXX)"
  printf '%s' "$GM_DECLARED" | tr '|' '\n' | grep -vE '^(plan)?$' | sort -u > "$GM_DECL_FILE"
  for _mf in "$GOVERN_MODES_DIR"/*.sh; do
    [ -f "$_mf" ] || continue
    b="$(basename "$_mf")"; printf '%s\n' "${b%.sh}"
  done | sort -u > "$GM_DISK_FILE"
  # undeclared: on disk, not declared.
  while IFS= read -r _m; do
    [[ -z "$_m" ]] && continue
    if ! grep -qxF "$_m" "$GM_DECL_FILE"; then
      DRIFT_GOVERN_MODES=$((DRIFT_GOVERN_MODES + 1))
      if [[ "$MODE" != "dry-run" ]]; then
        emit_finding "registry-parity-govern-modes-drift" "$_m" \
          "level" "error" "direction" "undeclared-mode" \
          "detail" "skills/govern/modes/$_m.sh on disk but not a declared --kind in process.sh"
      fi
      REPORT_LINES="${REPORT_LINES}- registry-parity-govern-modes-drift: $_m (undeclared-mode)"$'\n'
    fi
  done < "$GM_DISK_FILE"
  # declared-but-absent: declared, no modes/<kind>.sh.
  while IFS= read -r _m; do
    [[ -z "$_m" ]] && continue
    if ! grep -qxF "$_m" "$GM_DISK_FILE"; then
      DRIFT_GOVERN_MODES=$((DRIFT_GOVERN_MODES + 1))
      if [[ "$MODE" != "dry-run" ]]; then
        emit_finding "registry-parity-govern-modes-drift" "$_m" \
          "level" "error" "direction" "declared-but-absent" \
          "detail" "--kind $_m declared in process.sh but no skills/govern/modes/$_m.sh on disk"
      fi
      REPORT_LINES="${REPORT_LINES}- registry-parity-govern-modes-drift: $_m (declared-but-absent)"$'\n'
    fi
  done < "$GM_DECL_FILE"
  rm -f "$GM_DECL_FILE" "$GM_DISK_FILE"
fi

TOTAL=$((DRIFT_BIJECTION + DRIFT_SCRIPT + DRIFT_SCHEMA_VERSION + DRIFT_SUBTREE_FIELD + DRIFT_DISK_ORPHAN + DRIFT_MANIFEST_FICTION + DRIFT_CAP_INDEX_MODE + DRIFT_FULL_ROSTER + DRIFT_GOVERN_MODES))
printf "## Capability Registry Parity (%d drift: bijection=%d script=%d schema-version=%d subtree-field=%d disk-orphan=%d manifest-write-fiction=%d cap-index-mode=%d full-roster=%d govern-modes=%d; advisory manifest-write-fiction=%d)\n\n" \
  "$TOTAL" "$DRIFT_BIJECTION" "$DRIFT_SCRIPT" "$DRIFT_SCHEMA_VERSION" "$DRIFT_SUBTREE_FIELD" "$DRIFT_DISK_ORPHAN" "$DRIFT_MANIFEST_FICTION" "$DRIFT_CAP_INDEX_MODE" "$DRIFT_FULL_ROSTER" "$DRIFT_GOVERN_MODES" "$ADVISORY_MANIFEST_FICTION"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- No drift detected."
fi
exit 0
