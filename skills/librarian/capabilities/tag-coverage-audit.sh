#!/bin/bash
# tag-coverage-audit — Vault-wide tag coverage + taxonomy compliance audit.
# Walks non-exempt vault .md files, measures presence of `tags:` frontmatter
# field, classifies tags against the canonical allowlist from
# `governance/foundation-master.json#tagging.taxonomy.dimension_prefixes`.
# Foundation philosophy: bundle is source-of-truth for the taxonomy, manifest
# is source-of-truth for path-pattern exemptions. When dimension_prefixes is
# empty, prefix-validation is skipped and only the
# `missing_tags_field` / `empty_tags_field` findings fire. Foundation ships
# system-utility dimensions (status, log); user-facing dimensions land via
# overlay-master union-resolve (T-7+T-8 scope).
# Structural exemptions (always exempt; not user-configurable):
#   - Archive/**                       (frozen history)
#   - _test*                           (sandbox)
#   - Symlinks resolving to $PLANS_DIR (e.g., `Plans/`)
#   - is_plan_root_file OR depth >=2 under $PLANS_DIR
# User-extension exemptions (read from manifest.vault.tag_audit_exemptions[]):
#   case-pattern globs matched against $REL (vault-relative path).
# Findings emitted via lib/findings.sh:
#   - missing_tags_field            (no `tags:` field at all)
#   - empty_tags_field              (`tags: []`)
#   - unrecognized_tag_prefix       (tag prefix not in `_tag_prefixes`;
#                                    skipped when `_tag_prefixes` is empty)
# Lifecycle events via emit_event: start / batch progress / end summary.
# Usage:
#   tag-coverage-audit.sh [--scope SECTION] [--batch-size N] [--output FILE] [--verbose]
# Bash 3.2 clean per R-23.
set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

{ [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
  || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/plan-path.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/plan-path.sh"; } \
  || source "$_REPO_LIB/plan-path.sh"
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/frontmatter.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/frontmatter.sh"; } \
  || source "$_REPO_LIB/frontmatter.sh"
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh"; } \
  || source "$_REPO_LIB/user-manifest-read.sh"
# The shared vault-view walker — the audit descends the
# Work/ symlink view (Work=390 bodies) via the ONE primitive, replacing the `find`
# WITHOUT -L that reached only the ~4 real top-level files (symlink-inert).
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/vault-view-walk.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/vault-view-walk.sh"; } \
  || source "$_REPO_LIB/vault-view-walk.sh"
# G5 (S4 T-1): source the manifest API so the tag-coverage summary subtree
# persists to the librarian-manifest via manifest_set — makes the registry's declared
# writes_manifest_subtree: "drift_findings.tag_coverage" REAL, so it is removed from
# _parity_pending_manifest_writes[] in the same commit. paths.sh is already sourced
# above, so manifest.sh's idempotent guard reuses $CLAUDE_STATE_ROOT/$COORD_DIR.
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh"; } \
  || source "$_REPO_LIB/manifest.sh"

SCOPE=""
BATCH_SIZE=100
OUTPUT=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)      SCOPE="$2"; shift 2 ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    --verbose)    VERBOSE=true; shift ;;
    *)            echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

export FINDINGS_OUTPUT="$OUTPUT"

# Tag prefix allowlist sourced from foundation-master#tagging.taxonomy.dimension_prefixes.
# Foundation ships system-utility dimensions (status, log); user-facing dimensions
# (engagement, project, scope, etc.) pending overlay-master union-resolve (T-7+T-8).
# When allowlist is empty, prefix validation is skipped and only missing/empty-tags findings fire.
FOUNDATION_MASTER="${FOUNDATION_MASTER:-${GOVERNANCE_DIR:-${CLAUDE_HOME:-$HOME/.claude}/governance}/foundation-master.json}"
# Canonical governance read: tag-coverage-audit
# CONSUMES .tagging.taxonomy.dimension_prefixes as a runtime validation allowlist (fires
# unrecognized_tag_prefix against vault tags) — config-consumption, NOT asset-as-subject — so it
# must read the MERGED view (the :71 "pending overlay-master union-resolve" note is exactly this
# fix): an adopter overlay declaring engagement/* etc. would otherwise be silently dropped ->
# false findings. Redirect FOUNDATION_MASTER to the R-52 merged union once; the read below is
# unchanged. Degrades to the raw bundle if the merger is unavailable.
if [[ -f "$FOUNDATION_MASTER" ]]; then
  _OVL="${FOUNDATION_OVERLAY_LOAD:-${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/foundation-overlay-load.sh}"
  [[ -x "$_OVL" ]] || _OVL="$_REPO_LIB/foundation-overlay-load.sh"
  if [[ -x "$_OVL" ]]; then
    _UNION="$(mktemp 2>/dev/null || true)"
    if [[ -n "$_UNION" ]] && bash "$_OVL" --foundation-path "$FOUNDATION_MASTER" \
          --overlay-path "$(dirname "$FOUNDATION_MASTER")/overlay-master.json" --force-override > "$_UNION" 2>/dev/null \
          && [[ -s "$_UNION" ]]; then
      FOUNDATION_MASTER="$_UNION"; trap 'rm -f "$_UNION"' EXIT
    elif [[ -n "$_UNION" ]]; then rm -f "$_UNION"; fi
  fi
fi
ALLOWLIST_PREFIXES=""
if [[ -r "$FOUNDATION_MASTER" ]] && command -v jq >/dev/null 2>&1; then
  ALLOWLIST_PREFIXES=$(jq -r '.tagging.taxonomy.dimension_prefixes // [] | .[]' "$FOUNDATION_MASTER" 2>/dev/null | tr '\n' ' ')
fi

# Manifest-extension exempt patterns (path globs).
EXEMPT_PATTERNS=$(umr_get_array '.vault.tag_audit_exemptions')

# Resolve scope root.
if [[ -n "$SCOPE" ]]; then
  SCAN_ROOT="$VAULT_ROOT/$SCOPE"
  if [[ ! -d "$SCAN_ROOT" ]]; then
    echo "ERROR: scope directory not found: $SCAN_ROOT" >&2
    exit 1
  fi
else
  SCAN_ROOT="$VAULT_ROOT"
fi

# The walker emits paths rooted at `pwd -P` of the scan root; normalize VAULT_ROOT
# the same way so the vault-relative REL strip is robust across a /var -> /private
# (macOS) or other symlinked-root normalization.
VAULT_ROOT_REAL="$(cd "$VAULT_ROOT" 2>/dev/null && pwd -P || printf '%s' "$VAULT_ROOT")"

SCAN_COUNT=0
FINDING_COUNT=0
MISSING_COUNT=0
EMPTY_COUNT=0
UNRECOGNIZED_COUNT=0
BATCH_COUNT=0

emit_event "{ \"tag_coverage_audit_start\": \"$(date -Iseconds)\", \"scope\": \"${SCOPE:-full-vault}\" }"

# Relax strict error handling inside the scan loop — per-file parse errors are
# soft findings, not audit-fatal (same pattern as drift-sweep.sh).
set +e
set +o pipefail

# Pre-compute plans-folder real path for symlink resolution check.
PLANS_REAL=""
if [[ -n "${PLANS_DIR:-}" && -d "$PLANS_DIR" ]]; then
  PLANS_REAL=$(cd "$PLANS_DIR" 2>/dev/null && pwd -P)
fi

is_exempt_path() {
  local rel="$1"
  local abs="$2"

  # Structural defaults (always exempt).
  case "$rel" in
    Archive/*|Archive) return 0 ;;
    _test*)            return 0 ;;
  esac

  # User-extension exemptions from manifest.
  if [[ -n "$EXEMPT_PATTERNS" ]]; then
    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      # shellcheck disable=SC2254
      case "$rel" in
        $pattern) return 0 ;;
      esac
    done <<< "$EXEMPT_PATTERNS"
  fi

  # Resolve real path — if it escapes into $PLANS_DIR via symlink, exempt.
  local real
  real=$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P)/$(basename "$abs")
  if [[ -n "$PLANS_REAL" ]] && [[ "$real" == "$PLANS_REAL"/* ]]; then
    return 0
  fi

  return 1
}

# PASS 1 — walk + exemption + SCAN_COUNT only; queue each non-exempt .md file (in
# walk order) for a SINGLE batched frontmatter/tag-state pass below. This replaces
# the fresh `python3`+`import yaml` that was spawned PER FILE inside the walk
# (~19ms/file, ~57-61s spawn overhead on a 3k-file vault) with ONE interpreter
# invocation. Queue rows are `REL<TAB>ABS` (REL for the finding, ABS for extraction).
TCA_QUEUE="$(mktemp -t tca-queue.XXXXXX)"
TCA_TAB="$(printf '\t')"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$file" in *.md) ;; *) continue ;; esac   # walker emits all regular files
  SCAN_COUNT=$((SCAN_COUNT + 1))
  REL="${file#$VAULT_ROOT_REAL/}"

  if is_exempt_path "$REL" "$file"; then
    continue
  fi

  printf '%s%s%s\n' "$REL" "$TCA_TAB" "$file" >> "$TCA_QUEUE"

  BATCH_COUNT=$((BATCH_COUNT + 1))
  if [[ $BATCH_COUNT -ge $BATCH_SIZE ]]; then
    emit_event "{ \"progress\": $SCAN_COUNT, \"findings_so_far\": $FINDING_COUNT }"
    BATCH_COUNT=0
  fi
done < <(vault_view_walk "$SCAN_ROOT" 2>/dev/null)

# The SINGLE batched pass: extract frontmatter + classify tag-state for EVERY queued
# file in ONE python3 invocation. Preserves the per-file yaml-based detection
# byte-for-byte (adopter PyYAML portability is out of scope here). Emits one record
# per file (in walk order) for bash to consume:
#   M<TAB>REL   -> missing_tags_field
#   E<TAB>REL   -> empty_tags_field
#   P<TAB>REL   -> populated header, followed by its tags as
#   G<TAB>TAG   -> a tag under the current P (bash runs the prefix check)
TCA_BATCH="$(mktemp -t tca-batch.XXXXXX)"
python3 - "$TCA_QUEUE" > "$TCA_BATCH" <<'PYEOF'
import sys
queue_path = sys.argv[1]
try:
    import yaml
    HAVE_YAML = True
except Exception:
    HAVE_YAML = False

def extract_fm(path):
    # Mirror `awk '/^---$/{c++;next} c==1{print} c>=2{exit}'`: collect the lines
    # strictly between the first and second lines that are exactly `---`.
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return ""
    out = []
    c = 0
    for ln in text.split("\n"):
        if ln == "---":
            c += 1
            if c >= 2:
                break
            continue
        if c == 1:
            out.append(ln)
    return "\n".join(out)

def classify(fm_text):
    # EXACT mirror of the retired per-file python (yaml.safe_load + tag-state). An
    # empty FM (no/empty frontmatter) yaml.safe_load()s to None -> MISSING, matching
    # the retired bash empty-FM branch.
    if not HAVE_YAML:
        # Degraded (no PyYAML): still flag a no-frontmatter file as MISSING; otherwise
        # skip (matches the retired per-file path whose `import yaml` failure emitted
        # nothing for a non-empty FM).
        return ("MISSING", []) if not fm_text.strip() else None
    try:
        fm = yaml.safe_load(fm_text)
    except Exception:
        return ("MISSING", [])
    if not isinstance(fm, dict):
        return ("MISSING", [])
    if 'tags' not in fm:
        return ("MISSING", [])
    val = fm.get('tags')
    if val is None:
        return ("EMPTY", [])
    if isinstance(val, list):
        if len(val) == 0:
            return ("EMPTY", [])
        return ("POPULATED", [str(t) for t in val])
    if isinstance(val, str):
        return ("POPULATED", [val])
    return ("MISSING", [])

w = sys.stdout.write
try:
    with open(queue_path, encoding="utf-8", errors="replace") as qf:
        rows = qf.read().split("\n")
except OSError:
    rows = []
for row in rows:
    if not row:
        continue
    rel, _, abs_path = row.partition("\t")
    res = classify(extract_fm(abs_path))
    if res is None:
        continue
    state, tags = res
    if state == "MISSING":
        w("M\t%s\n" % rel)
    elif state == "EMPTY":
        w("E\t%s\n" % rel)
    elif state == "POPULATED":
        w("P\t%s\n" % rel)
        for t in tags:
            w("G\t%s\n" % t)
PYEOF

# PASS 2 — consume the batched records IN WALK ORDER; emit findings byte-identically
# via emit_finding + the SAME per-tag prefix check (verbatim).
CUR_REL=""
while IFS="$TCA_TAB" read -r KIND PAYLOAD; do
  case "$KIND" in
    M)
      FINDING_COUNT=$((FINDING_COUNT + 1))
      MISSING_COUNT=$((MISSING_COUNT + 1))
      emit_finding "missing_tags_field" "$PAYLOAD"
      ;;
    E)
      FINDING_COUNT=$((FINDING_COUNT + 1))
      EMPTY_COUNT=$((EMPTY_COUNT + 1))
      emit_finding "empty_tags_field" "$PAYLOAD"
      ;;
    P)
      CUR_REL="$PAYLOAD"
      ;;
    G)
      # Skip prefix validation when allowlist is empty (foundation default).
      [[ -z "$ALLOWLIST_PREFIXES" ]] && continue
      TAG="$PAYLOAD"
      # Strip leading `#` if present; strip surrounding quotes.
      CLEAN=$(echo "$TAG" | sed -e 's/^#//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
      PREFIX="${CLEAN%%/*}"
      [[ -z "$PREFIX" ]] && continue

      # Check allowlist membership.
      IS_ALLOWED=false
      for ALLOWED in $ALLOWLIST_PREFIXES; do
        if [[ "$PREFIX" == "$ALLOWED" ]]; then
          IS_ALLOWED=true
          break
        fi
      done

      if [[ "$IS_ALLOWED" = false ]]; then
        FINDING_COUNT=$((FINDING_COUNT + 1))
        UNRECOGNIZED_COUNT=$((UNRECOGNIZED_COUNT + 1))
        # Escape quotes in the value for JSON safety.
        SAFE_VAL=$(echo "$CLEAN" | sed 's/"/\\"/g')
        emit_finding "unrecognized_tag_prefix" "$CUR_REL" "value" "$SAFE_VAL"
      fi
      ;;
  esac
done < "$TCA_BATCH"
rm -f "$TCA_QUEUE" "$TCA_BATCH"

set -e
set -o pipefail

emit_event "{ \"tag_coverage_audit_end\": \"$(date -Iseconds)\", \"files_scanned\": $SCAN_COUNT, \"findings\": $FINDING_COUNT, \"missing_tags_count\": $MISSING_COUNT, \"empty_tags_count\": $EMPTY_COUNT, \"unrecognized_tag_count\": $UNRECOGNIZED_COUNT }"

# G5 (S4 T-1): persist the tag-coverage summary subtree to the
# librarian-manifest — makes the registry's declared
# writes_manifest_subtree: "drift_findings.tag_coverage" real (removed from
# _parity_pending_manifest_writes[] in the same commit), mirroring
# placement-validate.sh:224-226. Additive summary (files_scanned/findings/missing/
# empty/unrecognized) from the post-walk counters. Tolerates set -euo pipefail +
# empty VAULT_LOGS: the manifest + its lock live under the always-creatable
# $CLAUDE_STATE_ROOT/$COORD_DIR (G2/plan 110), so no non-empty VAULT_LOGS is needed.
_TC_SUBTREE="$(printf '{"last_scan":"%s","files_scanned":%d,"findings":%d,"missing":%d,"empty":%d,"unrecognized":%d}' \
  "$(date -u +%Y-%m-%dT%H:%M:%S)" "$SCAN_COUNT" "$FINDING_COUNT" "$MISSING_COUNT" "$EMPTY_COUNT" "$UNRECOGNIZED_COUNT")"
manifest_set '.drift_findings.tag_coverage' "$_TC_SUBTREE"
