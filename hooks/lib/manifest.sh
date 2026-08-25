# manifest.sh — Canonical read/write API for librarian-manifest.json.
# Landed: T-1 (2026-04-20), co-shipped with the
# `plan-index` capability extraction. Centralizes the JSON manifest
# manipulation pattern that was previously re-implemented inline across
# every capability that emits findings or reads prior state.
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/manifest.sh"
#   val=$(manifest_get '.generated' '')
#   manifest_ensure_skeleton                 # (implicit in every write below)
#   manifest_set '.generated' "$(manifest_iso_now)"
#   manifest_append_finding placement \
#       '{ "id":"placement-001", "file":"foo.md", "reason":"..." }'
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
  { [ -r "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" ] && source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"; } \
    || { [ -r "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh" ] && source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"; }
fi

# G2: the librarian read-replica manifest leaves the vault for the XDG
# state tier. Default → state/manifests/; lock co-moves to $COORD_DIR below.
MANIFEST_PATH="${MANIFEST_PATH:-$CLAUDE_STATE_ROOT/manifests/librarian-manifest.json}"

# G2/(T-62): transitional new-first/old-fallback READ resolver —
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

# manifest_ensure_skeleton
# Idempotent convergence to the eight roots schemas/librarian-manifest-schema.json
# declares required — schema_version, inventory, xref_graph, tags, scan_state,
# drift_findings, architect_recommendations, rename_history — plus the required
# sub-keys of the three roots that have them (inventory, scan_state,
# architect_recommendations; drift_findings declares none). Called before the first write in
# manifest_set and manifest_append_finding, so a manifest is structurally valid
# from its very first write rather than accreting only the subtrees that happen
# to get written.
#
# FIX — why this exists. The writers below start a missing manifest as `{}` and
# create only the intermediate objects on the written path, and no other code
# path seeds the required roots. The result was a manifest that could never
# satisfy its own schema, re-validated at every session close by the
# librarian-manifest-validate step. The convergence is in-place and happens on
# the next write, so an already-accreted partial manifest repairs ITSELF — no
# out-of-band data repair of an existing manifest is required or scheduled.
# The shipped canonical shape of the same document is
# templates/librarian-manifest-skeleton.json.
#
# Idempotent and strictly additive: it adds ABSENT keys only and never replaces
# a value the document already carries — including a present-but-wrong-type
# value, which is left intact for the validator to report rather than destroyed
# here. A converged manifest is not rewritten at all (no write, no mtime churn).
manifest_ensure_skeleton() {
  local tmp="${MANIFEST_PATH}.ensure.$$"
  local lockfile="$COORD_DIR/manifest.lock"
  mkdir -p "$(dirname "$lockfile")" "$(dirname "$MANIFEST_PATH")" 2>/dev/null || true
  python3 - "$MANIFEST_PATH" "$tmp" "$lockfile" <<'PY'
import copy, json, sys, os, fcntl
manifest_path = sys.argv[1]
tmp = sys.argv[2]
lockfile = sys.argv[3]

# The eight required roots in empty-but-valid shapes. Mirrors
# templates/librarian-manifest-skeleton.json byte-for-byte in content.
SKELETON = {
    "schema_version": "1.0.0",
    "inventory": {"by_type": {}, "by_path": {}},
    "xref_graph": {},
    "tags": {},
    "scan_state": {"last_scanned_at": None, "findings_by_capability": {}},
    # drift_findings seeds the PARENT ONLY. It is a per-SCOPE sub-leaf namespace
    # (schemas/librarian-manifest-schema.json :: drift_findings.description): each
    # capability that declares writes_manifest_subtree owns one leaf keyed by its own
    # scope, the schema declares NO required child, and a manifest that has never run a
    # given capability correctly carries no leaf for it. Seeding named children here
    # would re-invent placeholders for scopes that may never run.
    "drift_findings": {},
    "architect_recommendations": {"last_scanned_log": None, "items": []},
    "rename_history": [],
}


def fill(doc, skel):
    """Add absent keys only; recurse where both sides are objects. Returns True
    if anything was added. Never overwrites an existing value."""
    changed = False
    for key, val in skel.items():
        if key not in doc:
            doc[key] = copy.deepcopy(val)
            changed = True
        elif isinstance(val, dict) and isinstance(doc[key], dict):
            changed = fill(doc[key], val) or changed
    return changed


with open(lockfile, 'a') as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    try:
        with open(manifest_path) as f:
            doc = json.load(f)
    except Exception:
        doc = {}
    if not isinstance(doc, dict):
        # A non-object root cannot be converged without discarding the bytes on
        # disk. Leave it exactly as found; the validator reports it.
        raise SystemExit(0)
    if fill(doc, SKELETON):
        with open(tmp, 'w') as f:
            json.dump(doc, f, indent=2, ensure_ascii=False)
        os.replace(tmp, manifest_path)
PY
}

# manifest_set <jq-path> <value>
# Atomic write. Creates intermediate objects. <value> is treated as a JSON
# scalar: bare strings are quoted; numbers/bools/null/objects/arrays pass
# through if parseable, otherwise quoted as a string.
manifest_set() {
  local path="$1"
  local value="$2"
  manifest_ensure_skeleton   # converge the required roots BEFORE the first write
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
# Appends <finding-json> under drift_findings.<section>, creating what is missing.
# Does NOT auto-generate IDs — callers pass fully-formed finding objects, matching
# the existing emitter contract in drift-sweep / people-audit. ID auto-increment is
# a v2 feature.
#
# SHAPE — drift_findings is a per-SCOPE sub-leaf namespace, and <section> is a SCOPE.
# Each capability that declares writes_manifest_subtree owns exactly one leaf keyed by
# its own scope, and manifest_set replaces its target leaf wholesale, so a writer that
# touched the PARENT would obliterate every sibling scope. The owners split by write
# path, not by schema class:
#   - the manifest_set writers own the rich leaves — frontmatter-enforce persists
#     drift_findings.frontmatter (its provides_canonicality / size_monitoring /
#     schema_type_coverage finding LISTS live INSIDE that leaf, one level below this
#     namespace), placement-validate drift_findings.placement.<scope>, stale-detect
#     drift_findings.stale;
#   - THIS function owns the append-shaped scopes: the finding lands directly in
#     drift_findings.<section>[], which is the flat-list shape rename-detect.sh
#     (section rename_detected) — the sole production call site — writes.
# The schema declares no required child of drift_findings and enumerates no scope key,
# so neither shape needs a schema class. See the adjudication comment at the write.
manifest_append_finding() {
  local section="$1"
  local finding="$2"
  manifest_ensure_skeleton   # converge the required roots BEFORE the first write
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
    # HISTORICAL SHAPE SET, retained deliberately — behaviour, not contract.
    # This branch used to make EVERY section a list, including three the schema then
    # declared "type":"object" and listed in drift_findings.required[], so a write
    # against one of them produced a document librarian-manifest-validate (run at every
    # session close) rejected. The writer was moved to conform.
    # The schema has since dropped that required[] entirely — the three names were
    # vestigial at this depth (frontmatter-enforce persists them one level DEEPER,
    # inside drift_findings.frontmatter), so drift_findings now declares no required
    # child and either shape validates here. The set below is therefore no longer a
    # mirror of anything: it is kept because these three names are the ones a manifest
    # may already carry in the object shape this branch produced, and re-typing an
    # existing leaf is a data change this file does not make. A NEW append-shaped scope
    # is NOT added here — it gets the flat-list shape, like the sole production call
    # site (rename-detect.sh, section rename_detected).
    DF_OBJECT_SECTIONS = ("provides_canonicality", "size_monitoring",
                          "schema_type_coverage")
    df = doc.setdefault("drift_findings", {})
    if section in DF_OBJECT_SECTIONS:
        prior = df.get(section)
        if isinstance(prior, dict):
            sub = prior
        elif isinstance(prior, list):
            # A document the pre-adjudication writer already coerced to a list:
            # ADOPT those findings into the object rather than discard them.
            sub = {"findings": prior}
            df[section] = sub
        else:
            # Absent is now the ORDINARY case: ensure_skeleton seeds the
            # drift_findings parent only, so no scope leaf pre-exists. A value of
            # any other type cannot hold findings either; start a fresh object
            # rather than crash (mirrors the flat-list branch below).
            sub = {}
            df[section] = sub
        lst = sub.get("findings")
        if not isinstance(lst, list):
            lst = []
            sub["findings"] = lst
    else:
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

# manifest_append_rename_history <ndjson-file>
# The NAMED POPULATOR write-half for the librarian-manifest top-level
# rename_history[] root (schemas/librarian-manifest-schema.json declares the
# root; manifest_ensure_skeleton seeds it empty). Consumes a file of
# rename-detect NDJSON records ({root, old_path, new_path, commit_sha,
# committed_at, similarity}) and appends each as a durable history row
# {from, to, at, commit, root, similarity} — the row shape the
# doc-dependencies registry documents for rename_history audit trails.
# Deduplicated on (commit, from, to), so re-running detection over an
# overlapping git window never double-appends. Append-only: rows are never
# rewritten or pruned here. This is what lets a rename outlive the detector's
# 24-hour git-log window: detection persists the move once, and a consumer
# (rename-cascade --from-history) can repair inbound references at ANY later
# time instead of only while the git window still surfaces the rename.
manifest_append_rename_history() {
  local ndjson_file="$1"
  [ -s "$ndjson_file" ] || return 0
  manifest_ensure_skeleton   # converge the required roots BEFORE the first write
  local tmp="${MANIFEST_PATH}.tmp.$$"
  local lockfile="$COORD_DIR/manifest.lock"
  mkdir -p "$(dirname "$lockfile")" "$(dirname "$MANIFEST_PATH")" 2>/dev/null || true
  python3 - "$MANIFEST_PATH" "$ndjson_file" "$tmp" "$lockfile" <<'PY'
import json, sys, os, fcntl
manifest_path, ndjson_file, tmp, lockfile = sys.argv[1:5]
with open(lockfile, 'a') as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    try:
        with open(manifest_path) as f:
            doc = json.load(f)
    except Exception:
        doc = {}
    hist = doc.setdefault("rename_history", [])
    if not isinstance(hist, list):
        hist = []
        doc["rename_history"] = hist
    seen = set()
    for row in hist:
        if isinstance(row, dict):
            seen.add((row.get("commit", ""), row.get("from", ""), row.get("to", "")))
    added = 0
    for ln in open(ndjson_file):
        ln = ln.strip()
        if not ln:
            continue
        try:
            rec = json.loads(ln)
        except Exception:
            continue
        if not isinstance(rec, dict):
            continue
        frm, to = rec.get("old_path", ""), rec.get("new_path", "")
        if not frm or not to:
            continue
        key = (rec.get("commit_sha", ""), frm, to)
        if key in seen:
            continue
        seen.add(key)
        hist.append({
            "from": frm,
            "to": to,
            "at": rec.get("committed_at", ""),
            "commit": rec.get("commit_sha", ""),
            "root": rec.get("root", ""),
            "similarity": rec.get("similarity", None),
        })
        added += 1
    if added:
        with open(tmp, 'w') as f:
            json.dump(doc, f, indent=2, ensure_ascii=False)
        os.replace(tmp, manifest_path)
PY
}
