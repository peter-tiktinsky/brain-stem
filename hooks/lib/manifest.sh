# manifest.sh — Canonical read/write API for librarian-manifest.json.
# Landed: Sub-plan 01 T-1 (2026-04-20), co-shipped with the
# `plan-index` capability extraction. Centralizes the JSON manifest
# manipulation pattern that was previously re-implemented inline across
# every capability that emits findings or reads prior state.
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/manifest.sh"
#   val=$(manifest_get '.generated' '')
#   manifest_set '.generated' "$(manifest_iso_now)"
#   manifest_append_finding drift_canonicality \
#       '{ "id":"DC-001", "file":"foo.md", "reason":"..." }'
#   now=$(manifest_iso_now)
# Consumers (at ship time):
#   - capabilities/plan-index.sh            (shipped 2026-04-20, T-1)
#   - capabilities/stale-detect.sh          (shipped 2026-04-20, T-4)
#   - capabilities/placement-validate.sh    (shipped 2026-04-20, T-5)
#   - capabilities/frontmatter-enforce.sh   (shipped 2026-04-21, T-2)
#   - capabilities/sync-check.sh            (pending — T-3)
# Bash 3.2 clean per R-23 (macOS /bin/bash). Depends on $CLAUDE_STATE_ROOT
# (manifest home: state/manifests/) + $COORD_DIR (lock). Atomic writes use
# temp-file + mv. Concurrent-session safety via
# fcntl.flock on $COORD_DIR/manifest.lock — T-2e-i
# (carved into foundation 2026-04-30 from live ~/.claude/). Atomic rename
# alone prevents torn writes but not lost updates under concurrent
# multi-session writers; flock closes that race. Lock held only across
# the RMW critical section; readers (manifest_get) remain lock-free since
# reads tolerate stale-by-one-tick output.

# Idempotent paths.sh source guard.
if [[ -z "${CLAUDE_STATE_ROOT:-}" || -z "${COORD_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" 2>/dev/null \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
fi

# G2 (plan 110): the librarian read-replica manifest leaves the vault for the XDG
# state tier. Default → state/manifests/; lock co-moves to $COORD_DIR below.
MANIFEST_PATH="${MANIFEST_PATH:-$CLAUDE_STATE_ROOT/manifests/librarian-manifest.json}"

# G2/D3 (plan 110 T-62): transitional new-first/old-fallback READ resolver —
# exactly ONE release (v1.3.0). The manifest moved vault Logs/ → state/manifests/.
# A reader firing mid-upgrade (after the default flipped but before the
# operator-gated relocate-state.sh moved the file) must still find it at the OLD
# in-vault home. WRITERS (manifest_set/manifest_append_finding) always target
# $MANIFEST_PATH (new); only READS carry the fallback. This whole block is
# removed in v1.4.0 (T-60), after which readers resolve $MANIFEST_PATH only.
_manifest_read_path() {
  if [[ -f "$MANIFEST_PATH" ]]; then printf '%s' "$MANIFEST_PATH"; return 0; fi
  if [[ -n "${VAULT_LOGS:-}" && -f "$VAULT_LOGS/librarian-manifest.json" ]]; then
    printf '%s' "$VAULT_LOGS/librarian-manifest.json"; return 0
  fi
  printf '%s' "$MANIFEST_PATH"  # neither present → new (readers handle missing)
}

# manifest_iso_now — UTC ISO-8601 timestamp to the second.
# Matches the `generated:` field shape emitted by the legacy librarian runner.
manifest_iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%S"
}

# manifest_get <jq-path> [default]
# Null-safe read. Prints the value at <jq-path>, or <default> (empty string
# if omitted) when the path is absent / manifest file missing / parse fails.
manifest_get() {
  local path="$1"
  local default="${2:-}"
  local mp; mp="$(_manifest_read_path)"   # T-62: new-first/old-fallback (read only)
  if [[ ! -f "$mp" ]]; then
    printf '%s' "$default"
    return 0
  fi
  python3 - "$mp" "$path" "$default" <<'PY' 2>/dev/null || printf '%s' "$default"
import json, sys
path_str = sys.argv[2]
default = sys.argv[3]
try:
    with open(sys.argv[1]) as f:
        doc = json.load(f)
except Exception:
    sys.stdout.write(default)
    sys.exit(0)
# Minimal jq-path subset: .a.b.c (no filters, no arrays).
parts = [p for p in path_str.lstrip('.').split('.') if p]
cur = doc
for p in parts:
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        sys.stdout.write(default)
        sys.exit(0)
if isinstance(cur, (dict, list)):
    sys.stdout.write(json.dumps(cur))
elif cur is None:
    sys.stdout.write(default)
else:
    sys.stdout.write(str(cur))
PY
}

# manifest_set <jq-path> <value>
# Atomic write. Creates intermediate objects. <value> is treated as a JSON
# scalar: bare strings are quoted; numbers/bools/null/objects/arrays pass
# through if parseable, otherwise quoted as a string.
manifest_set() {
  local path="$1"
  local value="$2"
  local tmp="${MANIFEST_PATH}.tmp.$$"
  local lockfile="$COORD_DIR/manifest.lock"
  mkdir -p "$(dirname "$lockfile")" "$(dirname "$MANIFEST_PATH")" 2>/dev/null || true
  python3 - "$MANIFEST_PATH" "$path" "$value" "$tmp" "$lockfile" <<'PY'
import json, sys, os, fcntl
manifest_path = sys.argv[1]
path_str = sys.argv[2]
raw_value = sys.argv[3]
tmp = sys.argv[4]
lockfile = sys.argv[5]
with open(lockfile, 'a') as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    try:
        with open(manifest_path) as f:
            doc = json.load(f)
    except Exception:
        doc = {}
    parts = [p for p in path_str.lstrip('.').split('.') if p]
    if not parts:
        raise SystemExit("manifest_set: refusing to replace root document")
    # Coerce raw_value to JSON where possible.
    try:
        value = json.loads(raw_value)
    except Exception:
        value = raw_value
    cur = doc
    for p in parts[:-1]:
        if not isinstance(cur.get(p), dict):
            cur[p] = {}
        cur = cur[p]
    cur[parts[-1]] = value
    with open(tmp, 'w') as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
    os.replace(tmp, manifest_path)
PY
}

# manifest_append_finding <section> <finding-json>
# Appends <finding-json> to the drift_findings.<section> array, creating the
# array if missing. Does NOT auto-generate IDs — callers pass fully-formed
# finding objects, matching the existing emitter contract in drift-sweep /
# people-audit. ID auto-increment is a v2 feature.
manifest_append_finding() {
  local section="$1"
  local finding="$2"
  local tmp="${MANIFEST_PATH}.tmp.$$"
  local lockfile="$COORD_DIR/manifest.lock"
  mkdir -p "$(dirname "$lockfile")" "$(dirname "$MANIFEST_PATH")" 2>/dev/null || true
  python3 - "$MANIFEST_PATH" "$section" "$finding" "$tmp" "$lockfile" <<'PY'
import json, sys, os, fcntl
manifest_path = sys.argv[1]
section = sys.argv[2]
finding_raw = sys.argv[3]
tmp = sys.argv[4]
lockfile = sys.argv[5]
with open(lockfile, 'a') as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    try:
        with open(manifest_path) as f:
            doc = json.load(f)
    except Exception:
        doc = {}
    try:
        finding = json.loads(finding_raw)
    except Exception:
        # Permit bare strings; wrap under { "message": ... }.
        finding = {"message": finding_raw}
    df = doc.setdefault("drift_findings", {})
    lst = df.setdefault(section, [])
    if not isinstance(lst, list):
        # Defensive: replace with fresh list rather than crash.
        lst = []
        df[section] = lst
    lst.append(finding)
    with open(tmp, 'w') as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
    os.replace(tmp, manifest_path)
PY
}
