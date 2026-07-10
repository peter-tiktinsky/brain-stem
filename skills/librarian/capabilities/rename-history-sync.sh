#!/bin/bash
# rename-history-sync — Maintain the `rename_history` schema field on
# ~/.claude/hooks/doc-dependencies.json. Idempotent migration + append.
#
# Sub-commands:
#   migrate                 — add empty rename_history: [] to any entry missing it
#   append                  — read rename-detect NDJSON from stdin, append each
#                             matching {from,to,at,commit} row to the entry
#                             whose primary / mirrors[].file basename matches.
#
# CLI:
#   rename-history-sync.sh migrate
#   rename-history-sync.sh append < ndjson
#   rename-history-sync.sh --help
#
# Env:
#   DOC_DEP_FILE            override default registry path (testing).
#
# Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi

DOC_DEP_FILE_EFF="${DOC_DEP_FILE:-$HOME/.claude/hooks/doc-dependencies.json}"

CMD="${1:-}"
case "$CMD" in
  migrate)
    shift
    python3 - "$DOC_DEP_FILE_EFF" <<'PY'
import json, os, sys
p = sys.argv[1]
if not os.path.isfile(p):
    # LAZY-CREATE the provenance store (create-on-first-write). An
    # absent store gets the entries[] scaffold (librarian-manifest rename_history[] shape), then
    # migrate proceeds — was: sys.exit(2). NO new shipped member (the store is repo-only-by-design;
    # the generator hooks/ glob + install Step 2 exclude top-level hooks/*.json — operator ruling
    # 2026-07-09). Downstream consume-proofs read this lazy-created store.
    try:
        os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
        with open(p, "w") as _f:
            json.dump({"entries": []}, _f, indent=2, ensure_ascii=False)
            _f.write("\n")
    except Exception as _exc:
        print("rename-history-sync: could not lazy-create %s (%s)" % (p, _exc), file=sys.stderr)
        sys.exit(2)
with open(p) as f:
    doc = json.load(f)
changed = 0
for e in doc.get("entries", []):
    if isinstance(e, dict) and "rename_history" not in e:
        e["rename_history"] = []
        changed += 1
if changed:
    tmp = p + ".tmp.migrate"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, p)
print("rename-history-sync migrate: %d entries updated" % changed)
PY
    ;;
  append)
    shift
    STDIN_CAPTURE=$(mktemp -t rhs-stdin.XXXXXX)
    trap 'rm -f "$STDIN_CAPTURE"' EXIT
    cat > "$STDIN_CAPTURE"
    python3 - "$DOC_DEP_FILE_EFF" "$STDIN_CAPTURE" <<'PY'
import json, os, sys
p, stdin_path = sys.argv[1], sys.argv[2]
if not os.path.isfile(p):
    # LAZY-CREATE on an absent store (create-on-first-write), then
    # append proceeds — was: sys.exit(2). NO new shipped member (operator ruling 2026-07-09).
    try:
        os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
        with open(p, "w") as _f:
            json.dump({"entries": []}, _f, indent=2, ensure_ascii=False)
            _f.write("\n")
    except Exception as _exc:
        print("rename-history-sync append: could not lazy-create %s (%s)" % (p, _exc), file=sys.stderr)
        sys.exit(2)
with open(p) as f:
    doc = json.load(f)

records = []
try:
    for ln in open(stdin_path):
        ln = ln.strip()
        if not ln:
            continue
        try:
            obj = json.loads(ln)
        except Exception:
            continue
        op, np = obj.get("old_path"), obj.get("new_path")
        if not op or not np:
            continue
        records.append({
            "from": op,
            "to": np,
            "at": obj.get("committed_at") or "",
            "commit": obj.get("commit_sha") or "",
        })
except Exception:
    pass

if not records:
    print("rename-history-sync append: no records on stdin")
    sys.exit(0)

def entry_touches(entry, path):
    if not isinstance(entry, dict):
        return False
    candidates = []
    for k in ("primary", "primary_dir"):
        v = entry.get(k)
        if v:
            candidates.append(v.rstrip("/"))
    for m in (entry.get("mirrors") or []):
        if isinstance(m, dict) and m.get("file"):
            candidates.append(m["file"])
    base = os.path.basename(path)
    for c in candidates:
        # Match on basename (rename-detect emits paths rooted in repo; we don't
        # bind to repo-root here — the registry is vault-root-relative).
        if os.path.basename(c.rstrip("/")) == os.path.basename(path.rstrip("/")):
            return True
        if c == path:
            return True
    return False

# De-dup on (from, to, commit) per entry — idempotent append.
def already_has(history, rec):
    for h in history:
        if not isinstance(h, dict):
            continue
        if (h.get("from") == rec["from"]
                and h.get("to") == rec["to"]
                and h.get("commit") == rec["commit"]):
            return True
    return False

appended = 0
for rec in records:
    for e in doc.get("entries", []):
        if not isinstance(e, dict):
            continue
        # An entry is touched if either endpoint (from or to) matches one of
        # its tracked paths. This lets us record historical renames as well
        # as renames into a tracked path.
        if entry_touches(e, rec["from"]) or entry_touches(e, rec["to"]):
            e.setdefault("rename_history", [])
            if not already_has(e["rename_history"], rec):
                e["rename_history"].append(rec)
                appended += 1

if appended:
    tmp = p + ".tmp.append"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, p)

print("rename-history-sync append: %d row(s) appended across entries" % appended)
PY
    ;;
  -h|--help|"")
    awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
    exit 0
    ;;
  *)
    echo "rename-history-sync: unknown command '$CMD'" >&2
    exit 2
    ;;
esac

exit 0
