#!/bin/bash
# migrate-project-identity.sh — project:-field identity migration.
# Repurposes the legacy title-valued `project:` manifest field into the cwd-keyed
# spoke key (R-ARCH-PID field-triad, D2): for every plan-tree manifest.json,
#   title   := old `project` value, WHEN `title` is absent (move the display name)
#   project := the owning-spoke key resolved through the anchored-spoke registry
# It is the same migration on both paths: a fresh install never needs it (the
# corrected writers stamp correct semantics); existing adopters run it once as an
# upgrade-engine step (install.sh Step 11.7c). IDEMPOTENT — a second run finds
# zero manifests with a title-valued project and rewrites nothing.
# SAFETY:
#   - Malformed JSON manifests are SKIPPED with a diagnostic, never half-written.
#   - Only files whose fields ACTUALLY change are rewritten (no formatting churn
#     on untouched manifests — the plans tree is git-diffed).
#   - Every other field is preserved byte-for-byte (json round-trip, insertion
#     order preserved, indent=2 to match the writers' output).
#   - Self-healing residue assertion: after the pass, ZERO manifests may remain
#     with a title-valued project (value contains a space OR equals the title).
#     Non-zero residue => exit 1 (the caller reverts via git).
# USAGE:
#   migrate-project-identity.sh [--plans-root <dir>] [--dry-run]
# Env overrides:
#   PLANS_ROOT           plan-tree root (else paths.sh PLANS_DIR, else ~/.claude-plans)
#   SPOKE_REGISTRY_PATH  anchored-spoke registry (test isolation)
#   FOUNDATION_REPO      repo root (to locate spoke-resolve.sh in dev/test)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${FOUNDATION_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"

DRY_RUN="false"
PLANS_ROOT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plans-root) PLANS_ROOT_ARG="${2:-}"; shift 2 ;;
    --dry-run)    DRY_RUN="true"; shift ;;
    -h|--help)    /usr/bin/sed -n '2,33p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "migrate-project-identity: unexpected arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" 2>/dev/null || true
fi
PLANS_ROOT="${PLANS_ROOT_ARG:-${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
if [[ ! -d "$PLANS_ROOT" ]]; then
  echo "migrate-project-identity: plans root not found: $PLANS_ROOT" >&2
  exit 2
fi

# Resolve the spoke-resolve.sh library (live -> FOUNDATION_REPO -> this repo).
# This repo (tools/.. -> repo root) is the always-present fallback, independent
# of FOUNDATION_REPO (which the resolver uses only as the cwd anchor).
SPOKE_LIB=""
for _sr in \
  "${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/spoke-resolve.sh" \
  "$REPO_ROOT/skills/new-plan/lib/spoke-resolve.sh" \
  "$(cd "$SCRIPT_DIR/.." && pwd)/skills/new-plan/lib/spoke-resolve.sh"; do
  if [[ -f "$_sr" ]]; then SPOKE_LIB="$_sr"; break; fi
done
if [[ -z "$SPOKE_LIB" ]]; then
  echo "migrate-project-identity: spoke-resolve.sh not found (R-ARCH-13)" >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$SPOKE_LIB"

# The live total — read at run time, NEVER a hardcoded snapshot (AC step 1).
LIVE_COUNT=$(find "$PLANS_ROOT" -name manifest.json -type f 2>/dev/null | wc -l | tr -d ' ')
echo "migrate-project-identity: $LIVE_COUNT manifest.json under $PLANS_ROOT" >&2

# Every plan in this tree is keyed to the launch anchor it was created from. The
# migration resolves each manifest to a spoke key through the registry. For the
# durable plans tree the launch anchor is fixed per-plan; we resolve the spoke
# from the registry by treating the plans tree as the brain-stem spoke's history
# (the anchor every existing plan was authored under), with parent_plan lineage
# kept intact. The resolver is the single source of truth for the key, so a
# collision in the registry blocks the whole migration before any write.
SPOKE_KEY="$(spoke_resolve_from_cwd "$REPO_ROOT")" || {
  echo "migrate-project-identity: spoke resolution blocked (registry collision) — aborting" >&2
  exit 1
}
echo "migrate-project-identity: target spoke key = $SPOKE_KEY" >&2

python3 - "$PLANS_ROOT" "$SPOKE_KEY" "$DRY_RUN" <<'PY'
import json, os, re, sys, tempfile

plans_root, spoke_key, dry_run = sys.argv[1], sys.argv[2], sys.argv[3] == "true"

# A "title-valued project" heuristic (AC residue test): the value looks like a
# human display name — it contains whitespace, OR it equals the manifest title.
def is_title_valued(project, title):
    if not isinstance(project, str) or not project:
        return False
    if " " in project:
        return True
    if title and project == title:
        return True
    return False

manifests = []
for dirpath, dirnames, filenames in os.walk(plans_root):
    if "manifest.json" in filenames:
        manifests.append(os.path.join(dirpath, "manifest.json"))
manifests.sort()

# Matches a top-level (2-space-indented, default writer output) "project" line.
# Captures (indent)(prefix up to the value)(json-encoded value)(trailing comma?).
PROJECT_LINE = re.compile(r'^([ \t]*)"project"(\s*:\s*)(.+?)(,?)\s*$')

changed, skipped, untouched = [], [], 0
for path in manifests:
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
        m = json.loads(raw)
    except Exception as exc:
        skipped.append((path, str(exc)))
        print("migrate-project-identity: SKIP malformed %s (%s)" % (path, exc), file=sys.stderr)
        continue
    if not isinstance(m, dict):
        skipped.append((path, "top-level not an object"))
        print("migrate-project-identity: SKIP non-object %s" % path, file=sys.stderr)
        continue

    old_project = m.get("project")
    old_title = m.get("title")

    # Decide the migration semantics from the parsed object.
    move_title = (
        (old_title is None or old_title == "")
        and isinstance(old_project, str) and old_project
        and (is_title_valued(old_project, None) or old_project not in (spoke_key, "home"))
    )
    restamp = m.get("project") != spoke_key
    if not move_title and not restamp:
        untouched += 1
        continue

    # MINIMAL SURGICAL EDIT (preserve every other byte): rewrite ONLY the
    # "project" line (+ insert a sibling "title" line when the display name
    # moves). When "project" is absent, INSERT a "project" line at the head of
    # the object. Never round-trip-reformat the rest of the file.
    lines = raw.split("\n")
    target_idx = None
    for i, line in enumerate(lines):
        mt = PROJECT_LINE.match(line)
        if mt:
            try:
                if json.loads(mt.group(3)) == old_project:
                    target_idx = i
                    break
            except Exception:
                continue

    new_lines = list(lines)
    if target_idx is not None:
        # Replace the existing project line in place.
        mt = PROJECT_LINE.match(lines[target_idx])
        indent, sep, trailing = mt.group(1), mt.group(2), mt.group(4)
        new_lines[target_idx] = '%s"project"%s%s%s' % (indent, sep, json.dumps(spoke_key), trailing)
        if move_title:
            # Insert "title": <old project> immediately before the project line,
            # same indent + always a trailing comma (project follows it).
            new_lines.insert(target_idx, '%s"title"%s%s,' % (indent, sep, json.dumps(old_project)))
    else:
        # "project" is absent — find the opening brace line and insert a project
        # line right after it (the head of the object), inferring indent/sep from
        # the first existing key line for byte-consistency.
        brace_idx = None
        for i, line in enumerate(lines):
            if line.strip() == "{":
                brace_idx = i
                break
        if brace_idx is None:
            skipped.append((path, "no clean opening-brace line for project insert"))
            print("migrate-project-identity: SKIP (no insertable head) %s" % path, file=sys.stderr)
            continue
        # Infer indent + separator from the next key line.
        indent, sep = "  ", ": "
        keyline = re.compile(r'^([ \t]+)"[^"]+"(\s*:\s*)')
        for j in range(brace_idx + 1, len(lines)):
            km = keyline.match(lines[j])
            if km:
                indent, sep = km.group(1), km.group(2)
                break
        ins = [indent + '"project"' + sep + json.dumps(spoke_key) + ","]
        if move_title:
            ins = [indent + '"title"' + sep + json.dumps(old_project) + ","] + ins
        new_lines[brace_idx + 1:brace_idx + 1] = ins

    new_raw = "\n".join(new_lines)
    if new_raw == raw:
        untouched += 1
        continue

    # Sanity: the surgical result MUST still parse, and carry the intended fields.
    try:
        check = json.loads(new_raw)
    except Exception as exc:
        skipped.append((path, "surgical edit produced invalid JSON (%s)" % exc))
        print("migrate-project-identity: SKIP (surgical edit invalid) %s (%s)" % (path, exc), file=sys.stderr)
        continue
    if check.get("project") != spoke_key or (move_title and check.get("title") != old_project):
        skipped.append((path, "surgical edit did not yield expected fields"))
        print("migrate-project-identity: SKIP (surgical post-check failed) %s" % path, file=sys.stderr)
        continue

    changed.append(path)
    if not dry_run:
        d = os.path.dirname(path)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".manifest.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(new_raw)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)

# --- self-healing residue assertion (post-pass) -----------------------------
residue = []
for path in manifests:
    try:
        with open(path, encoding="utf-8") as fh:
            m = json.load(fh)
    except Exception:
        continue  # malformed already counted as skipped; not residue
    if not isinstance(m, dict):
        continue
    if is_title_valued(m.get("project"), m.get("title")):
        residue.append(path)

print(json.dumps({
    "total": len(manifests),
    "changed": len(changed),
    "untouched": untouched,
    "skipped": len(skipped),
    "skipped_paths": [p for p, _ in skipped],
    "residue": len(residue),
    "residue_paths": residue[:20],
    "dry_run": dry_run,
    "spoke_key": spoke_key,
}))

if residue and not dry_run:
    print("migrate-project-identity: FAIL — %d manifests still carry a title-valued project"
          % len(residue), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
