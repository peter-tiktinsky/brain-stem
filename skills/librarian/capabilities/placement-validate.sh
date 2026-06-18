#!/bin/bash
# placement-validate — Check that every file is in the correct location per routing rules.
# Sources `lib/findings.sh`.
# Rules per SKILL.md:
#   1. Vault root allowlist: CLAUDE.md, System Governance.md (foundation
#      ships only these two; System Backlog.md + System Backlog - Archive.md
#      retired per T-15 Tier B 2026-05-22 — backlog lifecycle now
#      librarian-owned at ~/.claude-plans/_backlog.md per
#      governance/plans-rules.json :: root_files).
#   2. Project folders: only `{Project} - *.md` + `_index.md` + `File-Index.md`
#   3. People files: must be in <cluster_folder>/*/People/ (read from manifest.vault.cluster_folder;
#      skipped when cluster_folder is unset)
#   5. Cluster root: standard files + CLAUDE.md + _index.md + File-Index.md (cluster-parameterized;
#      skipped when cluster_folder is unset)
#   6. Reference/ (Tier 1): no engagement-specific files
#   (rule 7, Logs/ allowed patterns, retired at G3 — vault Logs/ no longer ships)
# Index File Convention (always allowed):
#   - _index.md at any directory root
#   - File-Index.md at cluster + project roots
# CLI:
#   placement-validate.sh                     # emit findings
#   placement-validate.sh --scope <path>      # narrow scope
#   placement-validate.sh --dry-run           # summary counts only
# Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh"; } \
  || source "$_REPO_LIB/user-manifest-read.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh"; } \
  || source "$_REPO_LIB/manifest.sh"

SCOPE=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "placement-validate: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

SCOPE_ROOT="${SCOPE:-$VAULT_ROOT}"

# Read cluster folder from user-manifest (vault.cluster_folder); fall through
# when unset — cluster-specific placement rules skip cleanly when CLUSTER_DIR is empty.
CLUSTER_DIR=""
_USER_MANIFEST="${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
if [[ -r "$_USER_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
  CLUSTER_DIR=$(jq -r '.vault.cluster_folder // ""' "$_USER_MANIFEST" 2>/dev/null || echo "")
fi
unset _USER_MANIFEST
export CLUSTER_DIR

# Capture a machine-readable summary subtree the bash layer persists to the
# manifest (drift_findings.placement) via manifest_set — see MANIFEST_SUBTREE_OUT
# below. Kept off stdout so the NDJSON findings stream is never polluted.
MANIFEST_SUBTREE_OUT="$(mktemp -t placement-subtree-XXXXXX)"
export MANIFEST_SUBTREE_OUT

python3 - "$SCOPE_ROOT" "$DRY_RUN" <<'PY'
import json, os, re, sys, datetime

scope_root, dry_run_s = sys.argv[1:3]
dry_run = (dry_run_s == "true")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")
subtree_out = os.environ.get("MANIFEST_SUBTREE_OUT", "")

# Cluster folder — read from overlay-master via CLUSTER_DIR env (set by bash section).
# When empty, cluster-specific placement rules (Rules 2, 3, 5) fall through without firing.
CLUSTER_DIR = os.environ.get("CLUSTER_DIR", "").rstrip("/")

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# Vault root allowlist (CLAUDE.md + System Governance.md per foundation
# ship; System Backlog entries retired per T-15 Tier B 2026-05-22)
# + index-file convention.
VAULT_ROOT_ALLOWLIST = {
    "CLAUDE.md", "System Governance.md",
    "_index.md", "File-Index.md",
}

# Cluster-root allowlist — pattern-based (applied only when CLUSTER_DIR is set)
CLUSTER_STANDARD = re.compile(r"^(CLAUDE\.md|_index\.md|File-Index\.md|.+ - (Overview|Updates|Reference|PRD|Context)\.md)$")

# Project-folder allowlist — pattern-based
PROJECT_ALLOWLIST = re.compile(r"^(_index\.md|File-Index\.md|.+ - .+\.md)$")

# Directories to skip entirely
SKIP_DIRS = ("Archive", ".git", ".claude", ".obsidian", "_test")

findings_count = 0
scanned = 0

for dirpath, dirnames, filenames in os.walk(scope_root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith('.')]
    rel_dir = os.path.relpath(dirpath, scope_root)

    for fn in filenames:
        if fn.startswith("."):
            continue
        if not (fn.endswith(".md") or fn == "File-Index.md"):
            continue
        scanned += 1
        rel = os.path.join(rel_dir, fn) if rel_dir != "." else fn

        # --- Rule 1: Vault root allowlist
        if rel_dir == ".":
            if fn not in VAULT_ROOT_ALLOWLIST:
                emit({"finding": "placement-violation", "file": rel,
                      "issue": "File at vault root (not in allowlist)",
                      "suggested_location": "Move to appropriate subfolder",
                      "classification": "manual"})
                findings_count += 1
            continue

        # --- Rule 3: People files must be in <CLUSTER_DIR>/*/People/ (when cluster is set)
        fm_snip = ""
        try:
            fm_snip = open(os.path.join(dirpath, fn)).read(1024)
        except Exception:
            pass
        is_people = bool(re.search(r"^type:\s*people\s*$", fm_snip, re.MULTILINE))
        if CLUSTER_DIR and is_people and "/People/" not in "/" + rel.replace("\\", "/"):
            emit({"finding": "placement-violation", "file": rel,
                  "issue": f"People file outside {CLUSTER_DIR}/*/People/",
                  "suggested_location": f"{CLUSTER_DIR}/<name>/People/",
                  "classification": "auto-fix"})
            findings_count += 1
            continue

        # --- Rule 2: Project folder allowlist (cluster-parameterized; skip if no cluster)
        m_proj = re.match(
            rf"^{re.escape(CLUSTER_DIR)}/([^/]+)/Projects/([^/]+)/([^/]+)$", rel
        ) if CLUSTER_DIR else None
        if m_proj:
            proj_slug = m_proj.group(2)
            basename = m_proj.group(3)
            if not PROJECT_ALLOWLIST.match(basename):
                emit({"finding": "placement-violation", "file": rel,
                      "issue": f"Non-project-scoped file in Projects/{proj_slug}/",
                      "suggested_location": f"Rename to '{proj_slug} - <Topic>.md' or move",
                      "classification": "manual"})
                findings_count += 1
                continue

        # --- Rule 5: Cluster root allowlist (cluster-parameterized; skip if no cluster)
        m_eng = re.match(
            rf"^{re.escape(CLUSTER_DIR)}/([^/]+)/([^/]+)$", rel
        ) if CLUSTER_DIR else None
        if m_eng:
            if not CLUSTER_STANDARD.match(m_eng.group(2)):
                emit({"finding": "placement-violation", "file": rel,
                      "issue": "Non-standard file in engagement root",
                      "suggested_location": "Move to Projects/, Strategic/, Planning/, or rename to {Eng} - * pattern",
                      "classification": "manual"})
                findings_count += 1
                continue

        # Rule 7 (Logs/ allowed patterns) retired at G3 — vault Logs/ no longer
        # ships; the run-log home relocated to $CLAUDE_LOG_DIR (G4/G7).

if dry_run:
    print("placement-validate: scanned=%d findings=%d" % (scanned, findings_count))

# Write the manifest summary subtree (drift_findings.placement). The bash layer
# reads $MANIFEST_SUBTREE_OUT and calls manifest_set — mirrors xref-check's
# captured-summary / manifest_set '.xref_graph' pattern. Kept off stdout.
if subtree_out:
    subtree = {
        "last_scan": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
        "scanned": scanned,
        "findings_count": findings_count,
    }
    with open(subtree_out, "w") as f:
        f.write(json.dumps(subtree))
PY

# Persist the placement summary subtree to the librarian-manifest. This makes
# the registry's declared writes_manifest_subtree: "drift_findings.placement"
# real (3-notwired-swallowed-2 fix), mirroring xref-check.sh's manifest_set.
# Review-hardening (empty-VAULT_LOGS contract): a manifest write needs a
# configured vault — with empty VAULT_LOGS the manifest_set lockfile resolves to
# '/.coordination/manifest.lock' (uncreatable) and the helper raises under set -e,
# which a no-vault fresh adopter's session-close logs as a spurious capability
# error — but G2 (plan 110) moved the manifest under $CLAUDE_STATE_ROOT/manifests and
# its lock under $COORD_DIR (both always creatable), so the persist no longer needs a
# non-empty VAULT_LOGS. Gate only on having a finding subtree to write.
if [[ -s "$MANIFEST_SUBTREE_OUT" ]]; then
  manifest_set '.drift_findings.placement' "$(cat "$MANIFEST_SUBTREE_OUT")"
fi
rm -f "$MANIFEST_SUBTREE_OUT"

# === R-15 promotion: RETIRED 2026-05-22 per T-15 Tier B ===============
# The backlog-row-missing session-close finding was the librarian-side R-15
# promotion (lockstep peer with hooks/pre-write-guard.sh R-15 PL_CONTEXT
# injection retired in the same commit set). Backlog lifecycle now
# librarian-owned at ~/.claude-plans/_backlog.md per
# governance/plans-rules.json :: root_files (writers_allowed=[librarian];
# generated_by=librarian:backlog-index). The librarian:backlog-index
# capability contract lives in the registry
# (skills/librarian/capability-registry.json :: backlog-index.output_contract;
# the finding is emitted by capabilities/backlog-index.sh) and owns row
# presence/absence findings via its `backlog-row-missing-disposition`
# finding category — no parallel finding needed here.
# === end R-15 promotion ======================================================
