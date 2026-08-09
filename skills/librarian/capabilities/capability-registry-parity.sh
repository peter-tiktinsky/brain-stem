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
#   (i) the sibling govern skill's executable modes/ <-> process.sh declared
#       --kind set: every skills/govern/modes/*.sh must be a declared --kind in
#       process.sh's `case "$KIND" in` dispatcher, and every declared --kind must
#       have a modes/<kind>.sh — a strict disk<->declaration bijection in BOTH
#       directions. (govern-modes has no registry of its own; it is audited here
#       because the govern skill ships no parity gate.)
#       -> registry-parity-govern-modes-drift
#       GATED: only when skills/govern/process.sh + modes/ are resolvable (skipped
#       on a partial tree — no false drift).
#   (j) every capability's registry default_flags[] must be ACCEPTED by its body's
#       arg dispatcher — a declared default_flag the body's `case "$1" in` rejects
#       (falls through to the `*)` unknown-flag exit) is drift. A presence-only
#       gate never parsed a cap's parser, so a cap could declare a default flag it
#       rejects rc=2 and ship GREEN. STATIC analysis over the bodies + registry
#       only — the roster is NEVER executed (executing would commit to the vault).
#       -> registry-parity-flag-not-accepted
#   (k) every capability declaring `session-close-step-2` in invocation_modes must
#       map to a real `run_capability <cap>` callsite in session-close.sh — a
#       declared close-step-2 mode with no callsite is an inert declaration.
#       -> registry-parity-session-close-callsite-missing
#       GATED: the registry's ._parity_pending_session_close_callsites[] allowlist
#       downgrades the known transitional declarations to ADVISORY (warn; not
#       counted in TOTAL; parity stays non-RED) until the close wiring lands; a
#       NON-allowlisted declaration with no callsite fires HARD (error; counted;
#       turns parity RED). The allowlist is a bounded, provably-shrinking pending
#       inventory whose legal target state is EMPTY (the capstone-requires-EMPTY
#       drain contract — NOT a welded floor).
#   (l) every capability whose body issues a `git commit`/`git push` command MUST
#       be requires_confirmation:true AND NOT a member of `librarian-full` — the
#       structural backstop that makes an unconfirmed git-mutating full-roster cap
#       impossible to ship GREEN. requires_confirmation
#       had ZERO programmatic consumers before this arm; a per-cap hand guard is not
#       structural. (A git-commit is not a governed-file write, so a body's empty
#       writes[] does NOT disqualify — the predicate is confirmation + roster only.)
#       -> registry-parity-git-confirmation-missing
#   (m) every capability whose scan root derives from $VAULT_ROOT must actually REACH
#       the governed vault surface. The vault view is symlink-composed, so a walk that
#       does not descend symlinks reaches a handful of PHYSICAL root files instead of
#       the thousands behind the view — and every presence/declaration gate stays GREEN
#       while the capability audits almost nothing. Declaration is not reach.
#       -> registry-parity-walk-reach-drift
#       MEASURED, not assumed: the arm walks the probe root TWICE ITSELF (symlink-inert
#       vs followlinks + realpath cycle-guard, the external surfaces pruned at the
#       top on BOTH sides so the comparison is like-for-like), then compares each rostered
#       capability's DECLARED posture against those counts. Postures, read statically from
#       the comment-stripped body: shared-walker (sources hooks/lib/vault-view-walk.sh),
#       followlinks-true, followlinks-gated (followlinks=<var> whose assignment names the
#       lanes it admits), or symlink-inert. A symlink-inert walk that reaches FEWER files
#       than the followlinks count and does NOT declare the intentional prune set
#       (Plans/Projects/Wiki/Work/Skills) is drift; declaring that prune is the documented
#       escape hatch. The capability roster is NEVER EXECUTED (executing would commit to
#       the vault) — the arm does its own read-only counting walks.
#       DETERMINISTIC ON A NON-SYMLINKED ADOPTER VAULT: with no symlink view the two counts
#       are EQUAL, so no posture can reach fewer than the reference and the class cannot
#       false-positive there. GATED: skipped when no probe root resolves (an adopter with
#       no vault configured has nothing to measure — no false drift).
#   (n) every tag PREFIX a shipped generator emits must be REGISTERED in the composed
#       foundation-master.json tagging.taxonomy.dimension_prefixes. A generator that mints
#       `#<prefix>/<x>` onto a governed file writes a vocabulary its sibling readers reject:
#       tag-coverage-audit's allowlist and the write-time R-32/R-47 tag enforcement both
#       derive their accepted set from that same leaf, so an unregistered prefix means the
#       system flags files it wrote itself.
#       -> registry-parity-tag-prefix-unregistered
#       The PRODUCER ROSTER IS DERIVED AT RUNTIME by sweeping the shipped file set (the
#       governance/foundation-manifest.json member list, which IS the shipped roster) for the
#       frontmatter emission shape — never a hardcoded producer list, so a newly added
#       generator is covered the moment it lands. Hand-corrected rows are what let this drift
#       in the first place; the point is the assertion, not the row.
#       GATED: the registry's ._parity_pending_tag_prefixes[] allowlist names prefixes whose
#       REGISTRATION is a governance-pillar edit (an operator-serialized surface this audit
#       cannot make for itself). Those are emitted ADVISORY (warn; NOT counted in TOTAL, so
#       parity stays non-RED) and stay individually named on every run; a NON-allowlisted
#       unregistered prefix fires HARD (error; counted; turns parity RED). Same bounded,
#       provably-shrinking pending-inventory contract as classes (f) and (k) — legal target
#       state EMPTY, never a welded floor. Skipped when no composed master resolves.
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
#   WALK_REACH_ROOT_OVERRIDE  probe root for class (m) (default: $VAULT_ROOT; class
#                             skips when neither resolves to a readable directory)
#   TAG_PARITY_ROOT_OVERRIDE  shipped-tree root for class (n) (default: the librarian root's
#                             own grandparent — which IS $CLAUDE_HOME in a real install;
#                             class skips when no governance/foundation-master.json resolves
#                             under it, so a partial scratch tree sweeps nothing)
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
DRIFT_FLAG_ACCEPT=0
DRIFT_MODES_CALLSITE=0
ADVISORY_MODES_CALLSITE=0
DRIFT_GIT_CONFIRM=0
DRIFT_WALK_REACH=0
DRIFT_TAG_PREFIX=0
ADVISORY_TAG_PREFIX=0
REPORT_LINES=""
WALK_REACH_REPORT=""

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

# Class (j): flag-acceptance. Every capability's registry default_flags[] must be
# ACCEPTED by its body's arg dispatcher. STATIC analysis only — the roster is never
# executed (executing would commit to the vault). The body's accepted-flag set is
# the union of the flag tokens in its `case "$1" in` arms (a `-`-leading pattern up
# to `)`, `|`-split); a declared default_flag NOT in that set is drift (the body's
# `*)` unknown-flag arm would reject it rc!=0). argv-Python (R-24). Spec-only
# entries and entries without a disk body (class (b) reports the latter) are skipped.
FLAG_DRIFT_FILE=$(mktemp -t flag-accept-XXXXXX)
python3 - "$REGISTRY" "$LIBRARIAN_ROOT" > "$FLAG_DRIFT_FILE" <<'PY'
import json, re, sys
registry, root = sys.argv[1], sys.argv[2]
try:
    with open(registry, encoding="utf-8") as fh:
        reg = json.load(fh)
except Exception:
    sys.exit(0)
# accepted flags = union of the `-`-leading case-arm patterns in the body.
arm_re = re.compile(r'^\s*(-[^)\s]*)\)')
for name, v in sorted((reg.get("capabilities") or {}).items()):
    if not isinstance(v, dict):
        continue
    if v.get("implementation_status") == "spec-only":
        continue
    flags = v.get("default_flags") or []
    if not flags:
        continue
    script = v.get("script") or ""
    body = root + "/" + script
    try:
        with open(body, encoding="utf-8") as fh:
            text = fh.read()
    except Exception:
        continue  # missing body already reported by class (b)
    accepted = set()
    for ln in text.splitlines():
        m = arm_re.match(ln)
        if not m:
            continue
        for tok in m.group(1).split("|"):
            tok = tok.strip()
            if tok.startswith("-"):
                accepted.add(tok)
    for f in flags:
        if f not in accepted:
            print("%s\t%s" % (name, f))
PY
while IFS=$'\t' read -r name flag; do
  [[ -z "$name" ]] && continue
  DRIFT_FLAG_ACCEPT=$((DRIFT_FLAG_ACCEPT + 1))
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-flag-not-accepted" "$name" \
      "level" "error" "flag" "$flag" \
      "detail" "registry default_flag not accepted by the body's arg dispatcher (case \"\$1\" rejects it)"
  fi
  REPORT_LINES="${REPORT_LINES}- registry-parity-flag-not-accepted: $name → $flag (body rejects its own default flag)"$'\n'
done < "$FLAG_DRIFT_FILE"
rm -f "$FLAG_DRIFT_FILE"

# Class (k): session-close-step-2 <-> callsite bijection. A capability declaring
# `session-close-step-2` in invocation_modes must map to a real `run_capability
# <cap>` callsite in session-close.sh. A declared close-step-2 mode with no
# callsite is an inert declaration. The registry's ._parity_pending_session_close_callsites[]
# allowlist downgrades known transitional declarations to ADVISORY (not counted in
# TOTAL) until the close wiring lands (single-writer of close wiring); a
# NON-allowlisted declaration with no callsite fires HARD. GATED on session-close.sh
# being resolvable (a partial tree skips — no false drift).
SESSION_CLOSE="$CAPABILITIES_DIR/session-close.sh"
if [[ -f "$SESSION_CLOSE" ]]; then
  SC_ALLOWLIST_FILE=$(mktemp -t sc-callsite-allowlist-XXXXXX)
  jq -r '._parity_pending_session_close_callsites // [] | .[]' "$REGISTRY" 2>/dev/null | sort -u > "$SC_ALLOWLIST_FILE"
  # comment-stripped run_capability invocation set (a `run_capability <cap>` arg is
  # the real close callsite; a comment mention is not).
  SC_INVOKED_FILE=$(mktemp -t sc-invoked-XXXXXX)
  sed 's/#.*$//' "$SESSION_CLOSE" | grep -oE 'run_capability[[:space:]]+[a-z0-9-]+' \
    | awk '{print $2}' | sort -u > "$SC_INVOKED_FILE"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$name" "$SC_INVOKED_FILE" && continue   # real callsite present
    if grep -qxF "$name" "$SC_ALLOWLIST_FILE"; then
      ADVISORY_MODES_CALLSITE=$((ADVISORY_MODES_CALLSITE + 1))
      if [[ "$MODE" != "dry-run" ]]; then
        emit_finding "registry-parity-session-close-callsite-missing" "$name" \
          "level" "warn" "advisory" "true" \
          "detail" "declares session-close-step-2 but has no run_capability callsite in session-close.sh (allowlisted pending close wiring — capstone-requires-EMPTY drain)"
      fi
      REPORT_LINES="${REPORT_LINES}- registry-parity-session-close-callsite-missing (ADVISORY, allowlisted): $name (declared session-close-step-2, no callsite)"$'\n'
    else
      DRIFT_MODES_CALLSITE=$((DRIFT_MODES_CALLSITE + 1))
      if [[ "$MODE" != "dry-run" ]]; then
        emit_finding "registry-parity-session-close-callsite-missing" "$name" \
          "level" "error" \
          "detail" "declares session-close-step-2 but has no run_capability callsite in session-close.sh"
      fi
      REPORT_LINES="${REPORT_LINES}- registry-parity-session-close-callsite-missing: $name (declared session-close-step-2, no callsite)"$'\n'
    fi
  done < <(jq -r '.capabilities | to_entries[] | select(.value.invocation_modes // [] | index("session-close-step-2")) | .key' "$REGISTRY")
  rm -f "$SC_ALLOWLIST_FILE" "$SC_INVOKED_FILE"
fi

# Class (l): git-commit-body confirmation. Any capability whose body issues a
# `git commit`/`git push` command MUST be requires_confirmation:true AND NOT a
# member of `librarian-full` — the structural backstop that makes an unconfirmed
# git-mutating full-roster cap impossible to ship GREEN. requires_confirmation had
# ZERO programmatic consumers before this arm. Comment-stripped body scan (a
# git-commit mention inside a comment is not a command). The predicate excises the
# 'non-empty writes' sub-clause: a git-commit is not a governed-file write, so a
# body's empty output_contract.writes[] does NOT disqualify.
while IFS=$'\t' read -r name script modes reqconf; do
  [[ -z "$name" ]] && continue
  body="$LIBRARIAN_ROOT/$script"
  [[ -f "$body" ]] || continue   # missing body reported by class (b)
  # COMMAND-POSITION match only: a real `git commit`/`git push` invocation (line
  # start, or after ;/&&/||/|/backtick/`$(`), NOT a string-literal or detail-text
  # mention (which is exactly how THIS auditor names the tokens). Comment-stripped
  # first so a header/comment mention is never a false command.
  sed 's/#.*$//' "$body" | grep -qE '(^|[;&|`(]|\$\()[[:space:]]*git[[:space:]]+(commit|push)' || continue
  violation=""
  [[ "$reqconf" == "true" ]] || violation="requires_confirmation-not-true"
  case " $modes " in *" librarian-full "*) violation="${violation:+$violation; }git-mutating-cap-in-librarian-full" ;; esac
  [[ -z "$violation" ]] && continue
  DRIFT_GIT_CONFIRM=$((DRIFT_GIT_CONFIRM + 1))
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-git-confirmation-missing" "$name" \
      "level" "error" "violation" "$violation" \
      "detail" "body issues a git-mutating command but is not requires_confirmation:true AND out of librarian-full (the un-recurrable incident class)"
  fi
  REPORT_LINES="${REPORT_LINES}- registry-parity-git-confirmation-missing: $name ($violation)"$'\n'
done < <(jq -r '.capabilities | to_entries[] | select(.value.implementation_status != "spec-only") | [.key, .value.script, ((.value.invocation_modes // []) | join(" ")), (.value.requires_confirmation | tostring)] | @tsv' "$REGISTRY")

# Class (m): walk-reach. Every capability whose scan root derives from $VAULT_ROOT must
# actually REACH the governed vault surface behind the symlink-composed vault view. The
# defect this closes is silent: a followlinks=False walk over a symlink-composed vault
# reaches the handful of PHYSICAL root files while every presence/declaration gate stays
# GREEN, so the capability audits ~nothing and reports success. Declaration is not reach.
#
# The arm MEASURES: it walks the probe root twice ITSELF (never executing a capability —
# executing would commit to the vault) and compares each rostered capability's statically
# read posture against those counts. GATED on a resolvable probe root; DETERMINISTIC on a
# non-symlinked adopter vault, where the two counts are equal and no drift is expressible.
WALK_REACH_ROOT="${WALK_REACH_ROOT_OVERRIDE:-${VAULT_ROOT:-}}"
if [[ -n "$WALK_REACH_ROOT" && -d "$WALK_REACH_ROOT" ]]; then
  # (1) reference measurement — the same walk, twice, differing ONLY in followlinks. Both
  #     sides prune the five external symlink surfaces at the top level so the
  #     comparison isolates "does this descend the vault view" from "does this walk foreign
  #     trees". Standard realpath cycle-guard on the following side. argv-Python (R-24).
  WR_COUNTS=$(python3 - "$WALK_REACH_ROOT" <<'PY'
import os, sys
root = sys.argv[1]
EXTERNAL = ("Plans", "Projects", "Wiki", "Work", "Skills")

def count_md(follow):
    n = 0
    visited = set()
    for dirpath, dirnames, filenames in os.walk(root, followlinks=follow):
        if follow:
            rp = os.path.realpath(dirpath)
            if rp in visited:
                dirnames[:] = []
                continue
            visited.add(rp)
            dirnames[:] = [d for d in dirnames
                           if os.path.realpath(os.path.join(dirpath, d)) not in visited]
        if os.path.relpath(dirpath, root) == ".":
            dirnames[:] = [d for d in dirnames if d not in EXTERNAL]
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        n += sum(1 for fn in filenames if fn.endswith(".md"))
    return n

print("%d %d" % (count_md(False), count_md(True)))
PY
)
  WR_INERT="${WR_COUNTS%% *}"
  WR_REACH="${WR_COUNTS##* }"
  [[ "$WR_INERT" =~ ^[0-9]+$ ]] || WR_INERT=""
  [[ "$WR_REACH" =~ ^[0-9]+$ ]] || WR_REACH=""
fi

if [[ -n "${WR_INERT:-}" && -n "${WR_REACH:-}" ]]; then
  # (2) roster + posture — STATIC read of the comment-stripped bodies. The roster is derived
  #     at RUNTIME (a body that walks and whose scope names $VAULT_ROOT), never a hardcoded
  #     list, so a newly added vault-walking capability is covered the moment it lands.
  #     Comment-stripping matters: two non-walking capabilities mention VAULT_ROOT only in
  #     prose, and every walker carries followlinks=False in a comment describing the defect.
  WALK_REACH_FILE=$(mktemp -t walk-reach-XXXXXX)
  python3 - "$REGISTRY" "$LIBRARIAN_ROOT" "$WR_INERT" "$WR_REACH" "$(basename "$0")" > "$WALK_REACH_FILE" <<'PY'
import json, os, re, sys
registry, root, inert_s, reach_s, self_script = sys.argv[1:6]
inert, reach = int(inert_s), int(reach_s)
EXTERNAL = ("Plans", "Projects", "Wiki", "Work", "Skills")
try:
    with open(registry, encoding="utf-8") as fh:
        reg = json.load(fh)
except Exception:
    sys.exit(0)

for name, v in sorted((reg.get("capabilities") or {}).items()):
    if not isinstance(v, dict) or v.get("implementation_status") == "spec-only":
        continue
    script = v.get("script") or ""
    # The auditor's OWN probe walk is instrumentation, not a governed audit walk — exclude
    # the running body rather than the name, so the exclusion cannot rot on a rename.
    if os.path.basename(script) == self_script:
        continue
    try:
        with open(root + "/" + script, encoding="utf-8") as fh:
            text = fh.read()
    except Exception:
        continue  # missing body already reported by class (b)
    src = "\n".join(re.sub(r"#.*$", "", ln) for ln in text.splitlines())
    # ROSTER: it walks, and its scan scope derives from the vault root.
    if "os.walk(" not in src or "VAULT_ROOT" not in src:
        continue
    # POSTURE: every reach MECHANISM present, not just the first — a body can carry the
    # shared walker on one lane and a followlinks gate on another (that is exactly the
    # shape of the whole-vault capability), and a report that names only one hides the
    # lane the other covers.
    mechanisms = []
    lanes = "-"
    follow_vals = set(re.findall(r"followlinks\s*=\s*([A-Za-z_][A-Za-z0-9_]*)", src))
    gated = sorted(v2 for v2 in follow_vals if v2 not in ("True", "False"))
    if "vault_view_walk" in src:
        mechanisms.append("shared-walker")
    if "True" in follow_vals:
        mechanisms.append("followlinks-true")
    if gated:
        mechanisms.append("followlinks-gated")
        # The lane set the gate ADMITS, read off the gating variable's own assignment —
        # this is what makes "does lane X reach behind symlinks" a checkable fact.
        am = re.search(r"^[ \t]*%s[ \t]*=[ \t]*([^=].*)$" % re.escape(gated[0]), src, re.M)
        if am:
            toks = re.findall(r"""["']([a-z][a-z0-9_-]*)["']""", am.group(1))
            if toks:
                lanes = ",".join(sorted(set(toks)))
    posture = "+".join(mechanisms) if mechanisms else "symlink-inert"
    # The documented escape hatch: an intentional prune naming the external surfaces.
    declares_prune = all(('"%s"' % s) in src or ("'%s'" % s) in src for s in EXTERNAL)
    reached = inert if posture == "symlink-inert" else reach
    verdict = "drift" if (reached < reach and not declares_prune) else "ok"
    print("%s\t%s\t%s\t%s\t%d\t%d" % (verdict, name, posture, lanes, reached, reach))
PY
  while IFS=$'\t' read -r verdict name posture lanes reached expected; do
    [[ -z "$name" ]] && continue
    WALK_REACH_REPORT="${WALK_REACH_REPORT}- walk-reach: $name posture=$posture lanes=$lanes reached=$reached expected=$expected verdict=$verdict"$'\n'
    [[ "$verdict" == "drift" ]] || continue
    DRIFT_WALK_REACH=$((DRIFT_WALK_REACH + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-walk-reach-drift" "$name" \
        "level" "error" "posture" "$posture" "reached" "$reached" "expected" "$expected" \
        "detail" "VAULT_ROOT-walking capability is silently symlink-inert: it reaches $reached .md against the followlinks reach of $expected and declares no intentional external-surface prune"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-walk-reach-drift: $name ($posture: reached=$reached, followlinks reach=$expected)"$'\n'
  done < "$WALK_REACH_FILE"
  rm -f "$WALK_REACH_FILE"
fi

# Class (n): generator-emitted tag prefix <-> registered taxonomy. A generator that mints
# `#<prefix>/<x>` into a governed file's frontmatter writes a vocabulary its sibling readers
# reject — tag-coverage-audit's allowlist and the write-time R-32/R-47 tag enforcement both
# derive their accepted set from tagging.taxonomy.dimension_prefixes — so the system ends up
# flagging files it wrote itself. The producer roster is swept at RUNTIME out of the shipped
# file set, never hardcoded: a hand-maintained producer list is what let this drift.
# ROOT RESOLUTION IS ANCHORED ON THE LIBRARIAN ROOT'S OWN TREE, never on the ambient
# $CLAUDE_HOME. In a real install the two are the SAME path (skills/librarian lives under
# $CLAUDE_HOME), so production behaviour is identical either way — but they diverge for a
# caller running this body against a RELOCATED librarian root, and an ambient-$CLAUDE_HOME
# fallback made such a run sweep the operator's LIVE INSTALL instead of the tree under test.
# Anchoring on the tree the capability is part of is both the hermetic choice and the
# semantically correct one: this class audits its own shipped tree. A partial tree with no
# governance/ resolves to nothing and the class SKIPS, which is right — there is no shipped
# roster there to sweep.
TAG_PARITY_ROOT=""
if [[ -n "${TAG_PARITY_ROOT_OVERRIDE:-}" && -f "${TAG_PARITY_ROOT_OVERRIDE}/governance/foundation-master.json" ]]; then
  TAG_PARITY_ROOT="$TAG_PARITY_ROOT_OVERRIDE"
else
  _tp_cand="$(cd "$LIBRARIAN_ROOT/../.." 2>/dev/null && pwd)"
  [[ -n "$_tp_cand" && -f "$_tp_cand/governance/foundation-master.json" ]] && TAG_PARITY_ROOT="$_tp_cand"
  unset _tp_cand
fi
if [[ -n "$TAG_PARITY_ROOT" ]]; then
  TAG_PREFIX_ALLOWLIST_FILE=$(mktemp -t tag-prefix-allowlist-XXXXXX)
  jq -r '._parity_pending_tag_prefixes // [] | .[]' "$REGISTRY" 2>/dev/null | sort -u > "$TAG_PREFIX_ALLOWLIST_FILE"
  TAG_PREFIX_FILE=$(mktemp -t tag-prefix-XXXXXX)
  # R-52 READ path: config-consumption routes through the merger
  # (hooks/lib/foundation-overlay-load.sh), never a raw foundation-master read. This is not
  # gate bookkeeping — it is what makes the class CORRECT for adopters. An adopter registers a
  # new tag prefix through skills/govern/modes/tag-extension.sh, which proposes exactly this
  # leaf (tagging.taxonomy.dimension_prefixes) into their OVERLAY, and
  # hooks/lib/merge-strategy-registry.json declares that leaf a UNION leaf. Reading foundation
  # raw would see only the foundation's own prefixes and report a legitimately-registered
  # adopter prefix as drift — a false positive on precisely the extension path the ecosystem
  # ships. Resolved from TAG_PARITY_ROOT's OWN tree, never the ambient $CLAUDE_HOME, per the
  # same anchoring discipline as the root resolution above. Degrades loud-safe to the raw
  # bundle when the merger is absent (a partial tree) — never broken.
  TAG_PARITY_MASTER="$TAG_PARITY_ROOT/governance/foundation-master.json"
  TAG_PARITY_UNION=""
  _tp_ovl="$TAG_PARITY_ROOT/hooks/lib/foundation-overlay-load.sh"
  if [[ -f "$_tp_ovl" ]]; then
    TAG_PARITY_UNION=$(mktemp -t tag-prefix-union-XXXXXX)
    if bash "$_tp_ovl" --foundation-path "$TAG_PARITY_MASTER" \
         --overlay-path "$TAG_PARITY_ROOT/governance/overlay-master.json" --force-override \
         > "$TAG_PARITY_UNION" 2>/dev/null && [[ -s "$TAG_PARITY_UNION" ]]; then
      TAG_PARITY_MASTER="$TAG_PARITY_UNION"
    else
      rm -f "$TAG_PARITY_UNION"; TAG_PARITY_UNION=""
    fi
  fi
  unset _tp_ovl
  python3 - "$TAG_PARITY_ROOT" "$TAG_PARITY_MASTER" > "$TAG_PREFIX_FILE" <<'PY'
import json, os, re, sys
root = sys.argv[1]
# argv[2] is the MERGED (foundation U overlay) view when the merger resolved; the raw
# foundation bundle only as the loud-safe degradation.
master = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else os.path.join(root, "governance", "foundation-master.json")
try:
    with open(master, encoding="utf-8") as fh:
        registered = ((json.load(fh).get("tagging") or {}).get("taxonomy") or {}).get("dimension_prefixes")
except Exception:
    sys.exit(0)
if not isinstance(registered, list):
    # A wrong-shape leaf degrades to "no opinion" rather than flagging every producer —
    # the mis-shape itself is frontmatter-enforce's fail-loud surface, not this one's.
    sys.exit(0)
registered = set(p for p in registered if isinstance(p, str))

# THE SHIPPED ROSTER IS THE MANIFEST. Fall back to the emitting source dirs only when no
# manifest is present (a partial tree), so the sweep is never a hand-kept path list.
members = []
manifest = os.path.join(root, "governance", "foundation-manifest.json")
try:
    with open(manifest, encoding="utf-8") as fh:
        members = [f.get("path", "") for f in (json.load(fh).get("files") or [])]
except Exception:
    members = []
if not members:
    for sub in ("skills", "hooks", "templates", "vault-init"):
        base = os.path.join(root, sub)
        for dp, dns, fns in os.walk(base):
            dns[:] = [d for d in dns if not d.startswith(".")]
            members.extend(os.path.relpath(os.path.join(dp, fn), root) for fn in fns)

# The EMISSION shape: a frontmatter `tags:` array literal, and every `#<prefix>/` inside it.
# Written so this auditor's own body is not a producer (the pattern text never spells a
# literal emission), which keeps the sweep from finding itself.
tags_re = re.compile(r"tags:\s*\[([^\]]*)\]")
pref_re = re.compile(r"#([A-Za-z0-9][A-Za-z0-9_-]*)/")
seen = set()
for rel in sorted(set(m for m in members if m)):
    try:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except Exception:
        continue
    for tm in tags_re.finditer(text):
        for prefix in pref_re.findall(tm.group(1)):
            if prefix in registered:
                continue
            key = (prefix, rel)
            if key in seen:
                continue
            seen.add(key)
            print("%s\t%s" % (prefix, rel))
PY
  while IFS=$'\t' read -r prefix producer; do
    [[ -z "$prefix" ]] && continue
    if grep -qxF "$prefix" "$TAG_PREFIX_ALLOWLIST_FILE"; then
      ADVISORY_TAG_PREFIX=$((ADVISORY_TAG_PREFIX + 1))
      if [[ "$MODE" != "dry-run" ]]; then
        emit_finding "registry-parity-tag-prefix-unregistered" "$producer" \
          "level" "warn" "advisory" "true" "prefix" "$prefix" \
          "detail" "shipped generator emits the unregistered tag prefix '#$prefix/' (allowlisted pending — registering it is a governance-pillar edit this audit cannot make for itself; target state EMPTY)"
      fi
      REPORT_LINES="${REPORT_LINES}- registry-parity-tag-prefix-unregistered (ADVISORY, allowlisted): #$prefix/ ← $producer"$'\n'
    else
      DRIFT_TAG_PREFIX=$((DRIFT_TAG_PREFIX + 1))
      if [[ "$MODE" != "dry-run" ]]; then
        emit_finding "registry-parity-tag-prefix-unregistered" "$producer" \
          "level" "error" "prefix" "$prefix" \
          "detail" "shipped generator emits the tag prefix '#$prefix/', which is not in the composed foundation-master.json tagging.taxonomy.dimension_prefixes — the vocabulary its sibling readers (tag-coverage-audit, the write-time R-32/R-47 tag enforcement) reject"
      fi
      REPORT_LINES="${REPORT_LINES}- registry-parity-tag-prefix-unregistered: #$prefix/ ← $producer (emitted but not registered)"$'\n'
    fi
  done < "$TAG_PREFIX_FILE"
  rm -f "$TAG_PREFIX_FILE" "$TAG_PREFIX_ALLOWLIST_FILE"
  [[ -n "$TAG_PARITY_UNION" ]] && rm -f "$TAG_PARITY_UNION"
fi

TOTAL=$((DRIFT_BIJECTION + DRIFT_SCRIPT + DRIFT_SCHEMA_VERSION + DRIFT_SUBTREE_FIELD + DRIFT_DISK_ORPHAN + DRIFT_MANIFEST_FICTION + DRIFT_CAP_INDEX_MODE + DRIFT_FULL_ROSTER + DRIFT_GOVERN_MODES + DRIFT_FLAG_ACCEPT + DRIFT_MODES_CALLSITE + DRIFT_GIT_CONFIRM + DRIFT_WALK_REACH + DRIFT_TAG_PREFIX))
printf "## Capability Registry Parity (%d drift: bijection=%d script=%d schema-version=%d subtree-field=%d disk-orphan=%d manifest-write-fiction=%d cap-index-mode=%d full-roster=%d govern-modes=%d flag-not-accepted=%d session-close-callsite=%d git-confirmation=%d walk-reach=%d tag-prefix-unregistered=%d; advisory manifest-write-fiction=%d session-close-callsite=%d tag-prefix-unregistered=%d)\n\n" \
  "$TOTAL" "$DRIFT_BIJECTION" "$DRIFT_SCRIPT" "$DRIFT_SCHEMA_VERSION" "$DRIFT_SUBTREE_FIELD" "$DRIFT_DISK_ORPHAN" "$DRIFT_MANIFEST_FICTION" "$DRIFT_CAP_INDEX_MODE" "$DRIFT_FULL_ROSTER" "$DRIFT_GOVERN_MODES" "$DRIFT_FLAG_ACCEPT" "$DRIFT_MODES_CALLSITE" "$DRIFT_GIT_CONFIRM" "$DRIFT_WALK_REACH" "$DRIFT_TAG_PREFIX" "$ADVISORY_MANIFEST_FICTION" "$ADVISORY_MODES_CALLSITE" "$ADVISORY_TAG_PREFIX"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- No drift detected."
fi
# Class (m) per-capability reach ledger. Printed whenever the class RAN (a probe root
# resolved), drift or not, so the reach posture of every VAULT_ROOT-walking capability is
# a readable fact rather than an inference from silence — this is the read-only surface a
# coordinating verify-task asserts on (e.g. "does the --full lane reach behind symlinks").
if [[ -n "$WALK_REACH_REPORT" ]]; then
  printf '\n### Walk reach (probe root: %s)\n\n' "${WALK_REACH_ROOT:-<none>}"
  printf '%s' "$WALK_REACH_REPORT"
fi
exit 0
