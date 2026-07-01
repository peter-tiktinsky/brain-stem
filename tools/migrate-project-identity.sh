#!/bin/bash
# migrate-project-identity.sh — legacy display-name (title) rescue for plan manifests.
# One narrow, lossless job: when a plan-tree manifest.json carries a human display
# name in the `project:` field (a legacy shape) and has NO `title:` field, copy
# that display name into a new `title:` field. It NEVER writes `project:` — a
# genuinely unattributable legacy `project:` value is left untouched for a later,
# human-adjudicated ownership pass to reclassify; a value that is already a
# registered spoke key is left untouched by construction.
# It is the same operation on both paths: a fresh install never needs it (the
# writers stamp correct semantics); existing adopters run it once as an upgrade
# step. IDEMPOTENT — once the display name is rescued into `title:`, a second run
# finds nothing to move.
# SAFETY (never-clobber-a-registered-key invariant):
#   - The tool reads the registered spoke-key SET from the anchored-spoke registry
#     and only rescues a `project:` value that is NOT a registered key (a legacy
#     display name); a registered key is never treated as a display name.
#   - `project:` is never rewritten. The display name is COPIED, not moved.
#   - Malformed JSON manifests are SKIPPED with a diagnostic, never half-written.
#   - Only files whose fields actually change are rewritten (no formatting churn).
#   - Every other field is preserved byte-for-byte (surgical line edit; the rest
#     of the file is never round-trip-reformatted).
#   - Residue assertion (post-pass): a registry-membership self-consistency
#     invariant — every `project:` value is byte-identical to its pre-pass value
#     (the tool must never mutate `project:`). A wrong-spoke re-stamp would change
#     a `project:` value and so FAIL the assertion (exit 1; the caller reverts).
# USAGE:
#   migrate-project-identity.sh [--plans-root <dir>] [--dry-run]
# Env overrides:
#   PLANS_ROOT           plan-tree root (else paths.sh PLANS_DIR, else ~/.claude-plans)
#   SPOKE_REGISTRY_PATH  anchored-spoke registry (test isolation)
#   FOUNDATION_REPO      repo root, used ONLY to locate spoke-resolve.sh in dev/test
#                        (a library-location hint — NOT a cwd spoke anchor)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# FOUNDATION_REPO is a spoke-resolve.sh LIBRARY-LOCATION hint only (dev/test); it
# is NOT a cwd spoke anchor. The tool resolves NO spoke from any cwd.
REPO_ROOT="${FOUNDATION_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"

DRY_RUN="false"
PLANS_ROOT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plans-root) PLANS_ROOT_ARG="${2:-}"; shift 2 ;;
    --dry-run)    DRY_RUN="true"; shift ;;
    -h|--help)    /usr/bin/sed -n '2,41p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Resolve the spoke-resolve.sh library (live -> FOUNDATION_REPO -> this repo) for
# its registry-path helper ONLY — the tool never resolves a spoke from a cwd.
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

# Locate the registry (SPOKE_REGISTRY_PATH override -> live -> repo) and read the
# registered spoke-key SET as a JSON array, passed to the pass as an argv. The
# tool decides "legacy display name" vs "registered key" purely from this set.
REGISTRY_PATH="$(spoke_registry_path)" || REGISTRY_PATH=""
KEYS_JSON="$(python3 - "$REGISTRY_PATH" <<'PY'
import json, sys
path = sys.argv[1]
keys = []
try:
    reg = json.load(open(path, encoding="utf-8"))
    keys = [s.get("spoke_key", "") for s in reg.get("spokes", []) if s.get("spoke_key")]
except Exception:
    keys = []
print(json.dumps(keys))
PY
)"

LIVE_COUNT=$(find "$PLANS_ROOT" -name manifest.json -type f 2>/dev/null | wc -l | tr -d ' ')
echo "migrate-project-identity: $LIVE_COUNT manifest.json under $PLANS_ROOT" >&2
echo "migrate-project-identity: registered spoke keys = $KEYS_JSON" >&2

python3 - "$PLANS_ROOT" "$KEYS_JSON" "$DRY_RUN" <<'PY'
import json, os, re, sys, tempfile

plans_root, keys_json, dry_run = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
try:
    registered_keys = set(json.loads(keys_json))
except Exception:
    registered_keys = set()

manifests = []
for dirpath, dirnames, filenames in os.walk(plans_root):
    if "manifest.json" in filenames:
        manifests.append(os.path.join(dirpath, "manifest.json"))
manifests.sort()

# Match a top-level (writer-default 2-space-indent) "project" line; capture the
# json-encoded value so the title insert can be anchored next to it.
PROJECT_LINE = re.compile(r'^([ \t]*)"project"(\s*:\s*)(.+?)(,?)\s*$')

# Record the pre-pass project value per manifest for the immutability assertion.
pre_project = {}
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
    pre_project[path] = old_project

    # Title-rescue ONLY: copy a legacy display name into `title:` when title is
    # absent AND project holds a non-empty string that is NOT a registered spoke
    # key. `project:` is NEVER written.
    move_title = (
        (old_title is None or old_title == "")
        and isinstance(old_project, str) and old_project != ""
        and old_project not in registered_keys
    )
    if not move_title:
        untouched += 1
        continue

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
        mt = PROJECT_LINE.match(lines[target_idx])
        indent, sep = mt.group(1), mt.group(2)
        # Insert "title": <old project> immediately BEFORE the project line, same
        # indent, trailing comma (project follows). The project line is UNTOUCHED.
        new_lines.insert(target_idx, '%s"title"%s%s,' % (indent, sep, json.dumps(old_project)))
    else:
        # project value present but no clean single-line match — insert title at
        # the head of the object, inferring indent/sep from the first key line.
        brace_idx = None
        for i, line in enumerate(lines):
            if line.strip() == "{":
                brace_idx = i
                break
        if brace_idx is None:
            skipped.append((path, "no clean opening-brace line for title insert"))
            print("migrate-project-identity: SKIP (no insertable head) %s" % path, file=sys.stderr)
            continue
        indent, sep = "  ", ": "
        keyline = re.compile(r'^([ \t]+)"[^"]+"(\s*:\s*)')
        for j in range(brace_idx + 1, len(lines)):
            km = keyline.match(lines[j])
            if km:
                indent, sep = km.group(1), km.group(2)
                break
        new_lines[brace_idx + 1:brace_idx + 1] = [indent + '"title"' + sep + json.dumps(old_project) + ","]

    new_raw = "\n".join(new_lines)
    if new_raw == raw:
        untouched += 1
        continue

    # The surgical result MUST still parse, carry the rescued title, and leave
    # project byte-identical (the never-write-project invariant, per file).
    try:
        check = json.loads(new_raw)
    except Exception as exc:
        skipped.append((path, "surgical edit produced invalid JSON (%s)" % exc))
        print("migrate-project-identity: SKIP (surgical edit invalid) %s (%s)" % (path, exc), file=sys.stderr)
        continue
    if check.get("title") != old_project or check.get("project") != old_project:
        skipped.append((path, "surgical edit changed project or missed title"))
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

# --- residue: project-immutability self-consistency invariant ---------------
# Re-read every manifest; assert its project value is byte-identical to the
# pre-pass value. The tool must never mutate project: — a changed value (a
# wrong-spoke re-stamp) is residue and FAILS the pass.
residue = []
for path in manifests:
    if path not in pre_project:
        continue  # malformed/skipped — outside the immutability set
    try:
        with open(path, encoding="utf-8") as fh:
            m = json.load(fh)
    except Exception:
        continue
    if not isinstance(m, dict):
        continue
    if m.get("project") != pre_project[path]:
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
    "registered_keys": sorted(registered_keys),
}))

if residue and not dry_run:
    print("migrate-project-identity: FAIL — %d manifests had project: mutated (must never happen)"
          % len(residue), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
