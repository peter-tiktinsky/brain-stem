#!/bin/bash
# plan-parent-resolve — Walk parent_plan: chain for sub-task files, resolve
# inherited state, and emit drift findings.
#
# Wraps the parent-plan resolver algorithm as a CLI-invocable capability.
# Enforcement layer for ENFORCEMENT-MAP R-28 (parent_plan: chain integrity).
# Test harness: tests/plan-parent-resolve.sh.
#
# Usage:
#   plan-parent-resolve.sh                 # full corpus walk
#   plan-parent-resolve.sh --file <path>   # resolve chain for one file
#   plan-parent-resolve.sh --parent <slug> # list files whose chain includes <slug>
#   plan-parent-resolve.sh --classify      # PROPOSE an owning spoke per plan
#                                          # (T-3; propose-only, NEVER writes)
#   plan-parent-resolve.sh --dry-run       # (no-op — resolver is already read-only)
#
# Scope: sub-task files at depth >= 3 under $PLANS_DIR, excluding:
#   - plan-root files at depth 2 (spec.md, tasks.md, handoff.md,
#     00-ideation-brief.md, README.md, manifest.json)
#   - handoff.md at any depth (append-only session records)
#   - tests/**, _orchestrator/**, baselines/**, corpus/**,
#     regression-baseline/** (ephemeral diagnostic artifacts)
#
# _research/** is NOT excluded: declared research_artifacts[] pointers land under
# <plan>/_research/ and MUST be walkable by the resolver (R-FLOW-MAINT-8).
#
# Findings emitted (per SKILL.md-575):
#   parent-plan-inferred     — info  — missing field, parent from path
#   parent-plan-unresolvable — warn  — missing field, path yields nothing
#   parent-plan-broken-pointer — warn — parent slug does not exist
#   parent-plan-cycle        — error — visited set hit
#   parent-plan-chain-too-deep — error — chain exceeded depth 6
#   parent-plan-path-drift   — warn  — explicit field disagrees with path; ALSO
#                                      reused for the project:-stamp-vs-lineage
#                                      drift case (drift_class field distinguishes)
#
# R-ARCH-PID-DRIFT / R-FLOW-MAINT-7: the auto-stamped project: spoke key
# (D2 R-ARCH-PID field-triad) is re-validated against the anchored-spoke registry
# and the plan's lineage. A disagreement reuses the SHIPPED parent-plan-path-drift
# finding name (no new finding name is minted) with drift_class=project-stamp-*,
# severity warn, for human adjudication — NEVER a silent re-file (R-FLOW-MAINT-7).
#
# T-3: the --classify mode is a GROUND-TRUTH per-plan spoke
# CLASSIFIER layered on top of the drift validator. It reads the blessed 3-spoke
# set (brain-stem / personal-live-system) and the clean-room-rebuild
# temporal-axis pivot from the ownership-model artifact (ground truth, not
# a hardcoded assumption) and PROPOSES an owning spoke per plan from keyword
# (slug/title/spec) + superseded_by + parent_plan lineage + temporal signals. It
# emits a project-classify-proposal info finding per plan for human adjudication
# (T-4) — propose-only, NEVER mutates project: (same never-re-files
# posture as check_project_drift). The default corpus walk is unchanged.
#
# Read-only. Never writes. Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/frontmatter.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/frontmatter.sh"; } \
  || source "$_REPO_LIB/frontmatter.sh"

# Source the landed spoke-derivation discipline (skills/new-plan/lib/spoke-resolve.sh)
# rather than duplicating it (R-ARCH-PID-DRIFT re-validation reads, never re-derives).
# spoke_validate_override <key> exits 0 iff <key> is a registered anchored-spoke
# key — the registry IS the derivation authority (R-ARCH-13). If the lib is not
# resolvable, project-drift checking degrades to off (the parent_plan resolver is
# unaffected); SPOKE_RESOLVE_AVAILABLE gates the check.
_REPO_ROOT_RES="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
SPOKE_RESOLVE_AVAILABLE=0
for _sr in \
  "$CLAUDE_HOME_RES/skills/new-plan/lib/spoke-resolve.sh" \
  "$_REPO_ROOT_RES/skills/new-plan/lib/spoke-resolve.sh"; do
  if [ -r "$_sr" ]; then
    # shellcheck source=/dev/null
    source "$_sr" && SPOKE_RESOLVE_AVAILABLE=1
    break
  fi
done

MODE="corpus"
FILE_ARG=""
PARENT_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)    MODE="single"; FILE_ARG="$2"; shift 2 ;;
    --parent)  MODE="parent"; PARENT_FILTER="$2"; shift 2 ;;
    --classify) MODE="classify"; shift ;;  # T-3 propose-only classifier
    --dry-run) shift ;;  # No-op; accepted for chain-cleanliness
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "plan-parent-resolve: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

PLANS_ROOT="${PLANS_DIR_OVERRIDE:-$PLANS_DIR}"

if [[ ! -d "$PLANS_ROOT" ]]; then
  echo "plan-parent-resolve: PLANS_DIR not found: $PLANS_ROOT" >&2
  exit 3
fi

resolve_chain() {
  local file="$1"
  local visited=""
  local chain=""
  local depth=0
  local max_depth=6
  local parent
  # For manifest.json files, parse the JSON for top-level parent_plan.
  # For Markdown files, use the standard YAML frontmatter helper.
  if [[ "$file" == *.json ]]; then
    parent=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get('parent_plan', '') if isinstance(d, dict) else ''
    print(v if isinstance(v, str) else '')
except Exception:
    pass
" "$file" 2>/dev/null)
  else
    parent=$(fm_get_field "$file" "parent_plan")
  fi

  if [[ -z "$parent" ]]; then
    local rel="${file#$PLANS_ROOT/}"
    local top="${rel%%/*}"
    if [[ -n "$top" ]] && [[ -e "$PLANS_ROOT/$top" ]]; then
      echo "inferred:$top"
      return
    else
      echo "unresolvable"
      return
    fi
  fi

  while [[ -n "$parent" ]] && [[ $depth -lt $max_depth ]]; do
    case " $visited " in
      *" $parent "*)
        echo "cycle:$chain|$parent"
        return
        ;;
    esac
    visited="$visited $parent"
    if [[ -z "$chain" ]]; then
      chain="$parent"
    else
      chain="$chain|$parent"
    fi

    # Lookup: direct match, flat .md plan, or NN-<slug> form (per CLAUDE.md
    # rule #5: parent_plan value is the slug without numeric prefix).
    local parent_dir=""
    local resolved=0
    if [[ -d "$PLANS_ROOT/$parent" ]]; then
      parent_dir="$PLANS_ROOT/$parent"
      resolved=1
    elif [[ -f "$PLANS_ROOT/$parent.md" ]]; then
      resolved=1
    else
      for c in "$PLANS_ROOT"/*-"$parent"; do
        if [[ -d "$c" ]]; then
          parent_dir="$c"
          resolved=1
          break
        fi
      done
    fi
    if [[ "$resolved" -eq 0 ]]; then
      echo "broken:$parent"
      return
    fi

    local next_parent=""
    if [[ -n "$parent_dir" ]]; then
      if [[ -f "$parent_dir/spec.md" ]]; then
        next_parent=$(fm_get_field "$parent_dir/spec.md" "parent_plan")
      fi
      if [[ -z "$next_parent" ]] && [[ -f "$parent_dir/README.md" ]]; then
        next_parent=$(fm_get_field "$parent_dir/README.md" "parent_plan")
      fi
    fi
    # Plan-root self-pointer is a TERMINAL, not a cycle. A top-level plan's
    # depth-2 spec.md is R-28-EXEMPT ("the parent, not the child"); when it
    # carries parent_plan == its own slug, that is a degenerate self-pointer,
    # NOT a lineage hop. Treating the resolved parent's own slug as a next-hop
    # re-adds it to the visited set and trips a SPURIOUS parent-plan-cycle (the
    # visited-set check is built for genuine cross-plan A->B->A loops). A
    # depth-3 R-28-correct child stamp (parent_plan == its top-level plan) that
    # chains into such a root must terminate ok, not cycle. End the walk here;
    # a real cross-plan cycle has next_parent != parent and still trips below.
    if [[ "$next_parent" == "$parent" ]]; then
      next_parent=""
    fi
    parent="$next_parent"
    depth=$((depth + 1))
  done

  if [[ $depth -ge $max_depth ]]; then
    echo "too-deep:$depth"
    return
  fi

  echo "ok:$chain"
}

# read_project_field <file> — print the stamped project: value (empty if absent).
# manifest.json -> top-level JSON key; Markdown -> YAML frontmatter field.
read_project_field() {
  local file="$1"
  if [[ "$file" == *.json ]]; then
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get('project', '') if isinstance(d, dict) else ''
    print(v if isinstance(v, str) else '')
except Exception:
    pass
" "$file" 2>/dev/null
  else
    fm_get_field "$file" "project"
  fi
}

# check_project_drift <file> <rel> — re-validate the auto-stamped project: spoke
# key against the anchored-spoke registry (derivation authority) and the plan's
# lineage. On disagreement emit the SHIPPED parent-plan-path-drift finding name
# (R-FLOW-MAINT-7 — no new name minted) with a drift_class distinguishing the
# project-stamp case, severity warn, for human adjudication. NEVER re-files.
#
# Two sound read-side disagreement classes (R-ARCH-PID / R-ARCH-15):
#   project-stamp-unregistered — the stamped project: is not a registered spoke
#     key, so it cannot have been derived from the registry (e.g. a stale
#     title-valued value, or a wrong/unknown spoke key).
#   project-stamp-vs-lineage   — a sub-plan's project: disagrees with its
#     parent_plan master's project: (lineage groups WITHIN a spoke; child and
#     master must share the spoke key).
#
# Missing project: is NOT drift here — it is handled defensively (skip; absence
# is the U-path missing-as-empty case, never a crash).
check_project_drift() {
  local file="$1" rel="$2"
  [[ "$SPOKE_RESOLVE_AVAILABLE" -eq 1 ]] || return 0

  local stamped
  stamped="$(read_project_field "$file")"
  # Defensive: a missing/empty project: field is not re-validated (no crash).
  [[ -n "$stamped" ]] || return 0

  # Class 1 — the stamped key must be a registered anchored-spoke key.
  if ! spoke_validate_override "$stamped" >/dev/null 2>&1; then
    emit_finding "parent-plan-path-drift" "$rel" \
      "drift_class" "project-stamp-unregistered" \
      "stamped_project" "$stamped" \
      "level" "warn"
    return 0
  fi

  # Class 2 — lineage agreement: a sub-plan's project: must match its parent
  # master's project:. Resolve the master via the SAME parent-lookup the chain
  # walker uses (direct dir, flat .md, or NN-<slug> form).
  local parent
  if [[ "$file" == *.json ]]; then
    parent=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get('parent_plan', '') if isinstance(d, dict) else ''
    print(v if isinstance(v, str) else '')
except Exception:
    pass
" "$file" 2>/dev/null)
  else
    parent=$(fm_get_field "$file" "parent_plan")
  fi
  [[ -n "$parent" ]] || return 0

  local parent_dir=""
  if [[ -d "$PLANS_ROOT/$parent" ]]; then
    parent_dir="$PLANS_ROOT/$parent"
  elif [[ ! -f "$PLANS_ROOT/$parent.md" ]]; then
    for c in "$PLANS_ROOT"/*-"$parent"; do
      if [[ -d "$c" ]]; then parent_dir="$c"; break; fi
    done
  fi
  # No resolvable parent dir (flat .md or broken pointer) -> not a project-drift
  # case here; broken pointers are already surfaced by the chain walker.
  [[ -n "$parent_dir" ]] || return 0
  [[ -f "$parent_dir/manifest.json" ]] || return 0

  local parent_project
  parent_project="$(read_project_field "$parent_dir/manifest.json")"
  # Parent with no stamped project: cannot anchor a lineage-agreement check.
  [[ -n "$parent_project" ]] || return 0

  if [[ "$stamped" != "$parent_project" ]]; then
    emit_finding "parent-plan-path-drift" "$rel" \
      "drift_class" "project-stamp-vs-lineage" \
      "stamped_project" "$stamped" \
      "parent_plan" "$parent" \
      "parent_project" "$parent_project" \
      "level" "warn"
  fi
}

# ---- T-3: ground-truth per-plan spoke classifier ----------
# NEW propose-only logic layered on the same file as check_project_drift. Reads
# the blessed spoke set + temporal axis from the ownership-model artifact
# (ground truth), then PROPOSES an owning spoke per plan. It NEVER mutates
# project: — the same never-re-files posture as check_project_drift. Gated behind
# --classify so the default corpus walk (and its shipped drift findings) are
# untouched.
CLASSIFY_ADR=""
CLASSIFY_PIVOT="93"

# _classify_load_adr — locate the ownership-model artifact and read its
# ground truth: the blessed 3-spoke set (must be present) + the temporal-axis
# pivot plan number. Returns non-zero (classifier degrades to no-op) if the ADR
# is not resolvable — the model is a required input, never assumed.
_classify_load_adr() {
  if [[ -n "${ADR_OWNERSHIP_MODEL_PATH:-}" ]] && [[ -r "$ADR_OWNERSHIP_MODEL_PATH" ]]; then
    CLASSIFY_ADR="$ADR_OWNERSHIP_MODEL_PATH"
  else
    local c
    for c in "$PLANS_ROOT"/*/decisions/ADR-*plan-corpus-spoke-ownership-model.md; do
      [[ -r "$c" ]] && { CLASSIFY_ADR="$c"; break; }
    done
  fi
  [[ -n "$CLASSIFY_ADR" ]] && [[ -r "$CLASSIFY_ADR" ]] || return 1
  local k
  for k in brain-stem personal-live-system; do
    grep -q "$k" "$CLASSIFY_ADR" || return 1
  done
  local pv
  pv="$(grep -oE 'Plan [0-9]+ clean-room' "$CLASSIFY_ADR" | head -1 | grep -oE '[0-9]+' | head -1)"
  [[ -n "$pv" ]] && CLASSIFY_PIVOT="$pv"
  return 0
}

# classify_top <topdir> — echo "<proposed_spoke>|<basis>" for a top-level plan
# lineage. Signals: keyword (slug / title / spec-head) + superseded_by + the
# temporal axis (plan number vs the ADR pivot). Sub-plans inherit their master's
# proposal (parent_plan lineage grouping) — the caller resolves the lineage root
# and reuses its result. Delegates the keyword decision to an embedded python
# helper (same JSON/heredoc pattern the resolver already uses).
classify_top() {
  local topdir="$1"
  local plannum="${topdir%%-*}"
  python3 - "$PLANS_ROOT/$topdir" "$plannum" "$CLASSIFY_PIVOT" <<'PY'
import json, sys, os, re
topd, plannum, pivot = sys.argv[1], sys.argv[2], sys.argv[3]
slug = os.path.basename(topd)
title = ""; sb = ""
try:
    m = json.load(open(os.path.join(topd, "manifest.json")))
    title = str(m.get("title") or "")
    s = m.get("superseded_by")
    if isinstance(s, list):
        s = (s[0] if s else "")
    sb = "" if s is None else str(s)
except Exception:
    pass
spec = ""
try:
    with open(os.path.join(topd, "spec.md")) as f:
        for _ in range(60):
            spec += f.readline()
except Exception:
    pass
# Two haystacks. The DELIVERABLE IDENTITY (slug + title) is authoritative for the
# precursor test — the ratified interpretive ruling is "deliverable-target
# decides; later quarrying doesn't reclassify", so a bare *mention* in
# a post-pivot plan's spec prose (reference) must NOT flip it to precursor.
# The full context (+ spec head) augments the personal/repo-mechanics cues where
# the later-mention trap does not apply.
hay_id = (slug + " " + title).lower()
hay_full = (slug + " " + title + " " + spec).lower()
mnum = re.match(r"\d+", plannum)
pn = int(mnum.group()) if mnum else None
try:
    pv = int(pivot)
except Exception:
    pv = 93
sbm = re.search(r"\d+", sb or "")
sbn = int(sbm.group()) if sbm else None
def has_id(*ks):
    return any(k in hay_id for k in ks)
def has_full(*ks):
    return any(k in hay_full for k in ks)
# Rubric keyword cues (§Decision.3): precursor / personal / repo-mechanics.
# _ks: keyword-tuple guard — drops empty members. The public release cleaner strips
# build-era product names out of these quoted literals; an empty string would match
# EVERY haystack ("" in s is always True) and break the whole rubric, so the shipped
# cleaned form must degrade to FEWER keywords, never to match-all.
def _ks(*ks):
    return tuple(k for k in ks if k)
# Precursor-era spoke label — the cleaned public form falls back to a generic label
# (the "literal or fallback" idiom survives the cleaner with the fallback intact).
PRECURSOR_SPOKE = "" or "precursor-product"
PRECURSOR = _ks("claude-foundations", "", "onboarding-engine",
             "onboarding-flow", "dogfood", "foundation-substrate",
             "v3-organization", "v3-substrate", "consumer-lifecycle",
             "memory-scope-routing", "foundation-repo-launchd",
             "claude-system-organization")
PERSONAL = _ks("", "vault", "live-system", "operational-exhaust",
            "exhaust-relocation", "librarian", "enforcement", "orchestrator",
            "hooks-state", "dispatch", "workflow-hardening", "memory-system",
            "memory-realignment", "memory-substrate", "morning-brief",
            "engagement", "skill-optimizer", "skill-build", "token-efficiency",
            "compliance-security", "visual-generation", "multi-session",
            "cascade-waiver", "entity-parity", "track-vault", "auto-compact",
            "orphan-ideation", "daily-operational", "system-topology",
            "deferred-trigger", "plan-system-hardening", "plans-folder",
            "tag-taxonomy", "migration")
REPOMECH = _ks("", "clean-room", "ship-gate", "ship-transform",
            "foundation-manifest", "release-pipeline", "adopter", "binder",
            "governance", "manifest-regen", "docs-refresh", "docs-sync",
            "docs-release", "artifact-integrity", "universality",
            "upgrade-delivery")
# Temporal axis is the primary discriminator (§Decision.2 — the
# clean-room-rebuild pivot). Deliverable identity (slug/title) can still name
# precursor or personal work explicitly within either era.
precursor_id = has_id(*PRECURSOR)
if pn is not None and pn >= pv:
    # POST-PIVOT era -> brain-stem foundation-repo by default; the deliverable
    # identity can still name precursor or personal live-system work explicitly.
    if precursor_id:
        spoke, basis = PRECURSOR_SPOKE, "keyword-precursor"
    elif has_id(*PERSONAL):
        spoke, basis = "personal-live-system", "keyword-personal"
    elif has_full(*REPOMECH):
        spoke, basis = "brain-stem", "temporal-postpivot+repo-mechanics"
    else:
        spoke, basis = "brain-stem", "temporal-postpivot"
else:
    # PRE-PIVOT era -> precursor product vs personal live-system setup. Absent a
    # product deliverable identity, the era default is personal-live-system (the
    # ratified ruling: pre-pivot live-system work, even if later quarried).
    if precursor_id:
        spoke, basis = PRECURSOR_SPOKE, "keyword-precursor"
    elif sbn is not None and sbn == pv:
        spoke, basis = PRECURSOR_SPOKE, "superseded-by-pivot"
    elif has_full(*PERSONAL):
        spoke, basis = "personal-live-system", "keyword-personal"
    else:
        spoke, basis = "personal-live-system", "temporal-prepivot-default"
print(spoke + "|" + basis)
PY
}

# run_classify — walk every plan manifest (top-level + subs; infra/test/fixture
# dirs excluded), propose an owning spoke per plan (lineage-grouped), and emit a
# project-classify-proposal info finding for each. Propose-only: NO writes.
run_classify() {
  if ! _classify_load_adr; then
    echo "plan-parent-resolve --classify: ownership model not resolvable; classifier degraded to no-op" >&2
    return 0
  fi
  local last_top="" last_prop=""
  local file rel top prop spoke basis current
  while IFS= read -r -d '' file; do
    rel="${file#$PLANS_ROOT/}"
    # Infra dirs (leading _) are not plan state.
    case "$rel" in
      _*) continue ;;
    esac
    # Ephemeral diagnostics / synthetic fixtures are not plan state.
    case "/$rel/" in
      */tests/*|*/_orchestrator/*|*/baselines/*|*/corpus/*|*/regression-baseline/*|*/sp08-fixture-inputs/*|*/synthetic-plans/*) continue ;;
    esac
    top="${rel%%/*}"
    if [[ "$top" != "$last_top" ]]; then
      last_prop="$(classify_top "$top")"
      last_top="$top"
    fi
    prop="$last_prop"
    spoke="${prop%%|*}"
    basis="${prop#*|}"
    current="$(read_project_field "$file")"
    emit_finding "project-classify-proposal" "$rel" \
      "lineage_root" "$top" \
      "current_project" "$current" \
      "proposed_spoke" "$spoke" \
      "basis" "$basis" \
      "level" "info"
  done < <(find "$PLANS_ROOT" -type f -name 'manifest.json' -print0)
}

in_scope() {
  local file="$1"
  local rel="${file#$PLANS_ROOT/}"
  local rest="$rel" depth=1
  while [[ "$rest" == */* ]]; do
    rest="${rest#*/}"
    depth=$((depth + 1))
  done
  [[ $depth -ge 3 ]] || return 1

  [[ "$(basename "$file")" == "handoff.md" ]] && return 1

  # Test/fixture artifacts are not subject to R-28 inheritance — they are
  # ephemeral diagnostic outputs, not plan-state files.
  # tests/ + _orchestrator/ per CLAUDE.md rule #5; baselines/ + corpus/ +
  # regression-baseline/ added 2026-04-22 after parent-plan-resolve remediation
  # sweep (84/143 findings were test-fixture false positives).
  # _research/ is NOT excluded: declared research_artifacts[] pointers land there
  # and MUST be walkable by the resolver (R-FLOW-MAINT-8).
  case "/$rel/" in
    */tests/*|*/_orchestrator/*|*/baselines/*|*/corpus/*|*/regression-baseline/*|*/sp08-fixture-inputs/*|*/synthetic-plans/*) return 1 ;;
  esac

  # PRUNE the top-level infra dirs — _library binder/library
  # articles, _projects binder files, _drafts — from the R-28 lineage walk. They are
  # NOT plan-state (they were over-reaching 106+ binder/library files into the lineage).
  # TOP-LEVEL-specific (top=${rel%%/*}) so a <plan>/_research/ artifact (research_
  # artifacts[] pointers, R-FLOW-MAINT-8, header :24-25) stays walkable — its top segment
  # is the plan dir, not one of these three. Mirrors run_classify's leading-_ prune (469).
  # note: this is wrong-root-walk over-reach ONLY; broken:null (resolve_chain :180)
  # is dissolved by and is NOT touched here.
  local top="${rel%%/*}"
  case "$top" in
    _library|_projects|_drafts) return 1 ;;
  esac

  return 0
}

emit_resolution() {
  local file="$1"
  TOTAL=$((TOTAL + 1))
  local rel="${file#$PLANS_ROOT/}"
  local result
  result=$(resolve_chain "$file")

  case "$result" in
    ok:*)
      EXPLICIT=$((EXPLICIT + 1))
      local chain="${result#ok:}"
      local explicit_parent="${chain%%|*}"
      local path_top="${rel%%/*}"
      if [[ "$explicit_parent" != "$path_top" ]] && [[ -n "$path_top" ]] && [[ -e "$PLANS_ROOT/$path_top" ]]; then
        local path_top_slug="${path_top#*-}"
        if [[ "$explicit_parent" != "$path_top_slug" ]] && [[ "$explicit_parent" != "$path_top" ]]; then
          emit_finding "parent-plan-path-drift" "$rel" \
            "explicit" "$explicit_parent" \
            "path_top" "$path_top" \
            "level" "warn"
        fi
      fi
      ;;
    inferred:*)
      INFERRED=$((INFERRED + 1))
      emit_finding "parent-plan-inferred" "$rel" \
        "parent" "${result#inferred:}" \
        "level" "info"
      ;;
    unresolvable)
      UNRESOLVABLE=$((UNRESOLVABLE + 1))
      emit_finding "parent-plan-unresolvable" "$rel" "level" "warn"
      ;;
    broken:*)
      BROKEN=$((BROKEN + 1))
      emit_finding "parent-plan-broken-pointer" "$rel" \
        "parent" "${result#broken:}" \
        "level" "warn"
      ;;
    cycle:*)
      CYCLE=$((CYCLE + 1))
      emit_finding "parent-plan-cycle" "$rel" \
        "chain" "${result#cycle:}" \
        "level" "error"
      ;;
    too-deep:*)
      TOODEEP=$((TOODEEP + 1))
      emit_finding "parent-plan-chain-too-deep" "$rel" \
        "depth" "${result#too-deep:}" \
        "level" "error"
      ;;
  esac

  # R-ARCH-PID-DRIFT / R-FLOW-MAINT-7: re-validate the auto-stamped
  # project: spoke key against the registry + lineage for EVERY in-scope file
  # (independent of parent_plan presence — a top-level plan can carry a stale
  # project: stamp). Reuses the parent-plan-path-drift finding name above. The
  # --parent listing mode is a query, not a drift sweep, so skip the emission
  # there to keep its output a clean file list.
  if [[ "$MODE" != "parent" ]]; then
    check_project_drift "$file" "$rel"
  fi

  if [[ "$MODE" == "parent" ]]; then
    case "$result" in
      ok:*|inferred:*)
        local chain
        case "$result" in
          ok:*) chain="${result#ok:}" ;;
          inferred:*) chain="${result#inferred:}" ;;
        esac
        case "|$chain|" in
          *"|$PARENT_FILTER|"*) echo "$rel" ;;
        esac
        ;;
    esac
  fi
}

TOTAL=0
EXPLICIT=0
INFERRED=0
UNRESOLVABLE=0
BROKEN=0
CYCLE=0
TOODEEP=0

if [[ "$MODE" == "single" ]]; then
  if [[ ! -f "$FILE_ARG" ]]; then
    echo "plan-parent-resolve: --file not found: $FILE_ARG" >&2
    exit 3
  fi
  resolve_chain "$FILE_ARG"
  exit 0
fi

if [[ "$MODE" == "classify" ]]; then
  run_classify
  exit 0
fi

while IFS= read -r -d '' file; do
  if in_scope "$file"; then
    emit_resolution "$file"
  fi
done < <(find "$PLANS_ROOT" -type f \( -name '*.md' -o -name '*.json' \) -print0)

if [[ "$MODE" == "corpus" ]]; then
  printf "## plan-parent-resolve (%d files scanned)\n\n" "$TOTAL"
  printf -- "- Explicit parent_plan: %d\n" "$EXPLICIT"
  printf -- "- Path-inferred: %d\n" "$INFERRED"
  printf -- "- Unresolvable: %d\n" "$UNRESOLVABLE"
  printf -- "- Broken pointers: %d\n" "$BROKEN"
  printf -- "- Cycles detected: %d\n" "$CYCLE"
  printf -- "- Chain too deep: %d\n" "$TOODEEP"
fi
