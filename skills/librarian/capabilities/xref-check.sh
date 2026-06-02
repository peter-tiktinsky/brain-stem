#!/bin/bash
# xref-check — Scan for broken wikilinks, orphaned files, stale cross-references.
#
# Usage:
#   xref-check.sh                        # --recent (last 7 days), default
#   xref-check.sh --full                 # entire vault
#   xref-check.sh --scope <path>         # single file or dir
#   xref-check.sh --include-logs         # include Logs/ in orphan detection
#
# Wikilink regex: \[\[([^\]|]+)(\|[^\]]+)?\]\]
# Resolves by searching for <target>.md anywhere in vault.
#
# Finding classes:
#   xref-broken-link      — wikilink target not found (error)
#   xref-people-one-way   — A→B in People/ without reciprocal B→A (warn)
#   xref-orphan           — file has zero inbound links (info, excluded by default
#                            for Logs/, Archive/, CLAUDE.md, _index.md, File-Index.md)
#
# Manifest: xref_graph section updated via manifest_set (entire subtree —
# resolved-row drop-out pattern).
#
# Env overrides:
#   VAULT_ROOT_OVERRIDE  — override vault scan root
#   XREF_SCOPE           — override scope (path) from env
#   MANIFEST_PATH        — standard manifest.sh env
#   FINDINGS_OUTPUT      — standard findings.sh env
#
# Bash 3.2 clean; heavy lifting in Python heredoc.

set -u
set -o pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_ROOT:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh"; } \
  || source "$_REPO_LIB/manifest.sh"

MODE="recent"
SCOPE_PATH=""
INCLUDE_LOGS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)          MODE="full"; shift ;;
    --recent)        MODE="recent"; shift ;;
    --scope)         MODE="scope"; SCOPE_PATH="$2"; shift 2 ;;
    --include-logs)  INCLUDE_LOGS=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "xref-check: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

VAULT_SCAN_ROOT="${VAULT_ROOT_OVERRIDE:-$VAULT_ROOT}"
[[ -n "${XREF_SCOPE:-}" ]] && { MODE="scope"; SCOPE_PATH="$XREF_SCOPE"; }

if [[ ! -d "$VAULT_SCAN_ROOT" ]]; then
  echo "xref-check: vault root not found: $VAULT_SCAN_ROOT" >&2
  exit 3
fi

# Build graph + emit findings in one Python pass.
RESULT=$(python3 - "$VAULT_SCAN_ROOT" "$MODE" "$SCOPE_PATH" "$INCLUDE_LOGS" <<'PY'
import os, re, sys, json, time
from pathlib import Path

vault = Path(sys.argv[1])
mode = sys.argv[2]
scope_path = sys.argv[3]
include_logs = sys.argv[4] == "1"

WIKILINK_RE = re.compile(r"\[\[([^\]|]+)(\|[^\]]+)?\]\]")

# Excluded dirs at walk level.
EXCLUDE_DIRS = {".git", ".obsidian", ".trash", "Archive"}
ORPHAN_EXCLUDE_BASENAMES = {"CLAUDE.md", "_index.md", "File-Index.md", "System Governance.md"}
# Meetings/, Daily/, Inbox/ are expected-orphan by design — generated content that
# does not receive inbound wikilinks.
ORPHAN_EXCLUDE_DIRS_DEFAULT = {"Archive", "Logs", "Meetings", "Daily", "Inbox"} if not include_logs else {"Archive", "Meetings", "Daily", "Inbox"}

# Sources that legitimately CONTAIN wikilink-shaped strings pointing at broken
# targets because their purpose is auditing broken links elsewhere. Skip
# broken-link emission for these sources (structural false-positive fix).
# Still participates in inbound-link graph for orphan detection.
BROKEN_LINK_SOURCE_EXEMPT_PREFIXES = (
    "Logs/session-auto-close-",
    "Logs/session-close-",
    "Logs/broken-wikilinks-",
    "Logs/wikilink-manual-triage-",
    "Logs/xref-",
)

# Collect all .md files + filename -> full-path map (first wins).
target_map = {}  # basename_no_ext -> [paths]
all_files = []

now = time.time()
recent_cutoff = now - 7 * 86400

def in_scope(p):
    if mode == "full":
        return True
    if mode == "recent":
        try:
            return p.stat().st_mtime >= recent_cutoff
        except OSError:
            return False
    if mode == "scope":
        sp = Path(scope_path)
        if sp.is_file():
            return p.resolve() == sp.resolve()
        try:
            p.resolve().relative_to(sp.resolve())
            return True
        except (ValueError, OSError):
            return False
    return True

for root, dirs, files in os.walk(vault):
    dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith(".")]
    for fn in files:
        if not fn.endswith(".md"):
            continue
        p = Path(root) / fn
        all_files.append(p)
        stem = p.stem  # e.g. "Foo.md" → "Foo"
        target_map.setdefault(stem.lower(), []).append(p)

# Build inbound-link graph + emit broken wikilink findings.
inbound = {p: 0 for p in all_files}
scoped_files = [p for p in all_files if in_scope(p)]

broken = 0
people_oneway = 0
orphan = 0

findings = []

for src in scoped_files:
    try:
        text = src.read_text(errors="replace")
    except Exception:
        continue
    src_rel = str(src.relative_to(vault))
    # Exempt audit/report sources from broken-link emission (still counts inbound).
    exempt_src = any(src_rel.startswith(pref) for pref in BROKEN_LINK_SOURCE_EXEMPT_PREFIXES)
    for m in WIKILINK_RE.finditer(text):
        target_raw = m.group(1).strip()
        # Table-cell wikilinks use `\|` as escape for the cell divider:
        # `[[Target\|Display]]`. The regex `[^\]|]+` stops at the `|`, leaving
        # a trailing backslash on target_raw. Strip it before resolving.
        # (structural false-positive fix)
        if target_raw.endswith("\\"):
            target_raw = target_raw[:-1].rstrip()
        # Strip # anchor + / path delimiters.
        base = target_raw.split("#")[0].split("|")[0].strip()
        if not base:
            continue
        # Normalize: strip trailing .md if present; match by stem lowercase.
        if base.lower().endswith(".md"):
            base = base[:-3]
        # Extract just the filename portion after last /
        base_fn = base.split("/")[-1]
        key = base_fn.lower()
        hits = target_map.get(key, [])
        if hits:
            for h in hits:
                inbound[h] = inbound.get(h, 0) + 1
        else:
            if exempt_src:
                continue
            # Broken wikilink.
            findings.append({
                "finding": "xref-broken-link",
                "file": src_rel,
                "target": target_raw,
                "level": "error",
            })
            broken += 1

# Bidirectional People check.
people_by_name = {}
for p in all_files:
    if "/People/" in str(p) and p.stem != "_index":
        people_by_name[p.stem.lower()] = p

for src, src_path in people_by_name.items():
    try:
        text = src_path.read_text(errors="replace")
    except Exception:
        continue
    # Find references to other People files.
    refs = set()
    for m in WIKILINK_RE.finditer(text):
        base = m.group(1).split("#")[0].split("|")[0].strip().split("/")[-1]
        if base.lower().endswith(".md"):
            base = base[:-3]
        if base.lower() in people_by_name and base.lower() != src:
            refs.add(base.lower())
    for other in refs:
        other_path = people_by_name[other]
        try:
            other_text = other_path.read_text(errors="replace")
        except Exception:
            continue
        back_refs = set()
        for m in WIKILINK_RE.finditer(other_text):
            b = m.group(1).split("#")[0].split("|")[0].strip().split("/")[-1]
            if b.lower().endswith(".md"):
                b = b[:-3]
            back_refs.add(b.lower())
        if src not in back_refs:
            findings.append({
                "finding": "xref-people-one-way",
                "file": str(src_path.relative_to(vault)),
                "links_to": other,
                "level": "warn",
            })
            people_oneway += 1

# Orphan detection — only in scoped files.
for p in scoped_files:
    if p.name in ORPHAN_EXCLUDE_BASENAMES:
        continue
    rel = p.relative_to(vault)
    if any(part in ORPHAN_EXCLUDE_DIRS_DEFAULT for part in rel.parts):
        continue
    if inbound.get(p, 0) == 0:
        findings.append({
            "finding": "xref-orphan",
            "file": str(rel),
            "level": "info",
        })
        orphan += 1

# Emit summary.
out = {
    "total_files": len(all_files),
    "scoped_files": len(scoped_files),
    "broken": broken,
    "people_oneway": people_oneway,
    "orphan": orphan,
    "findings": findings,
}
print(json.dumps(out))
PY
)

# Extract summary (excluding findings); emit findings; write manifest subtree.
python3 - "$RESULT" <<'PY'
import json, sys, os
doc = json.loads(sys.argv[1])
findings_out = os.environ.get("FINDINGS_OUTPUT", "")
if findings_out:
    with open(findings_out, "a") as f:
        for fnd in doc["findings"]:
            f.write(json.dumps(fnd) + "\n")
else:
    for fnd in doc["findings"]:
        print(json.dumps(fnd))
PY

# Parse summary counts + build manifest subtree in a single argv-based Python pass.
# (Heredoc scripts that also read from stdin via pipe cause an empty-stdin bug on
# some bash/python combos — heredoc is passed as stdin, shadowing the pipe.)
SUMMARY=$(python3 - "$RESULT" <<'PY'
import json, sys, datetime
doc = json.loads(sys.argv[1])
subtree = {
    "last_scan": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
    "total_files": doc["total_files"],
    "scoped_files": doc["scoped_files"],
    "broken": doc["broken"],
    "people_oneway": doc["people_oneway"],
    "orphan": doc["orphan"],
}
print(doc["broken"])
print(doc["orphan"])
print(doc["people_oneway"])
print(doc["total_files"])
print(doc["scoped_files"])
print(json.dumps(subtree))
PY
)
BROKEN=$(echo "$SUMMARY" | sed -n '1p')
ORPHAN=$(echo "$SUMMARY" | sed -n '2p')
PEOPLE=$(echo "$SUMMARY" | sed -n '3p')
TOTAL=$(echo "$SUMMARY" | sed -n '4p')
SCOPED=$(echo "$SUMMARY" | sed -n '5p')
SUBTREE=$(echo "$SUMMARY" | sed -n '6p')

manifest_set '.xref_graph' "$SUBTREE"

# Report.
ISSUES=$((BROKEN + PEOPLE))
printf "## Cross-References (%d issues)\n\n" "$ISSUES"
printf -- "- Files scanned: %d / %d total\n" "$SCOPED" "$TOTAL"
printf -- "- Broken wikilinks: %d\n" "$BROKEN"
printf -- "- People one-way refs: %d\n" "$PEOPLE"
printf -- "- Orphans (info): %d\n" "$ORPHAN"
