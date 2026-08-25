#!/bin/bash
# xref-check — Scan for broken wikilinks, orphaned files, stale cross-references.
#
# Extracted from the librarian SKILL.md pseudocode.
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
# SECOND GRAMMAR (additive): markdown links `[text](relative/target)` are
# resolved source-relative against the file's PHYSICAL directory via a
# pre-built physical-path index from the same walk (no per-link stat; realpath
# + one exists() only on an index miss). Resolved .md targets join the same
# inbound graph (an md-link keeps a file out of the orphan set) and the People
# bidirectional check reads both grammars. Wikilink behavior is unchanged.
#
# Finding classes:
#   xref-broken-link      — wikilink target not found (error)
#   xref-broken-mdlink    — markdown-link target does not resolve from the
#                            source file's directory (error; same source
#                            exemptions + symlink-surface emission suppression)
#   xref-people-one-way   — A→B in People/ without reciprocal B→A (warn)
#   xref-orphan           — file has zero inbound links (info, excluded by default
#                            for Logs/, Archive/, CLAUDE.md, _index.md, File-Index.md)
#
# Manifest: xref_graph section updated via manifest_set (entire subtree —
# resolved-row drop-out pattern per T-2 precedent from).
#
# MEMORY-NAMESPACE RESOLUTION (resolution only, never emission). A wikilink whose
# target lives in the memory corpus — feedback_*/reference_*/project_* under
# $CLAUDE_HOME/rules, $CLAUDE_HOME/memory and $CLAUDE_HOME/projects/*/memory —
# resolves for the reader but lives OUTSIDE the vault, so a vault-only walk reported
# it broken. That was a standing ~13% noise floor on this capability's headline
# finding class, and a noise floor is how a real break stops being read.
#
# The namespace is ENUMERATED FROM DISK AT SCAN TIME, never a static prefix list.
# That is the load-bearing choice: a `feedback_`/`reference_`/`project_` allowlist
# encodes ONE corpus's naming convention, would be wrong for an adopter who names
# memories differently, and — worse — would suppress a genuinely DEAD memory ref by
# prefix alone. Enumerating means a link resolves because the file is there, and a
# link to a deleted memory is STILL reported broken.
#
# Resolution ONLY: memory files never enter the vault graph. They add no inbound
# link counts, never become orphan-emission subjects, and never make a vault
# basename look ambiguous. With no memory corpus present the set is empty and
# behaviour is byte-identical to a vault-only scan.
#
# Env overrides:
#   VAULT_ROOT_OVERRIDE  — override vault scan root
#   XREF_SCOPE           — override scope (path) from env
#   MEMORY_NS_ROOTS      — colon-separated memory-namespace roots (default: the three
#                          $CLAUDE_HOME surfaces above). Empty string = disable.
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

# Source the shared vault-view walker + materialize its
# file list so the graph build descends the symlink view (2630 md) via the ONE
# primitive instead of os.walk(followlinks=False) (4 md; cross-surface wikilinks
# mis-flagged, intra-surface graphs unvalidated). The python block reads XREF_WALK_LIST
# and FALLS BACK to os.walk when it is empty (symlink-inert floor).
XREF_WALK_LIST=""
_VVW_LIB="${VAULT_VIEW_WALK:-$CLAUDE_HOME_RES/hooks/lib/vault-view-walk.sh}"
[ -r "$_VVW_LIB" ] || _VVW_LIB="$_REPO_LIB/vault-view-walk.sh"
if [ -r "$_VVW_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_VVW_LIB"
  if command -v vault_view_walk >/dev/null 2>&1; then
    XREF_WALK_LIST="$(mktemp -t xref-walk.XXXXXX)"
    trap 'rm -f "${XREF_WALK_LIST:-}"' EXIT
    vault_view_walk "$VAULT_SCAN_ROOT" > "$XREF_WALK_LIST" 2>/dev/null || true
  fi
fi
export XREF_WALK_LIST

# The resolved CLAUDE_HOME the memory-namespace enumeration keys off, exported so the
# python block never has to re-derive it (an unset CLAUDE_HOME would silently make the
# namespace empty and quietly restore the noise floor).
MEMORY_NS_HOME="$CLAUDE_HOME_RES"
export MEMORY_NS_HOME

# Build graph + emit findings in one Python pass.
RESULT=$(python3 - "$VAULT_SCAN_ROOT" "$MODE" "$SCOPE_PATH" "$INCLUDE_LOGS" <<'PY'
import os, re, sys, json, time
from pathlib import Path
from urllib.parse import unquote

vault = Path(os.path.realpath(sys.argv[1]))   # match the walker's pwd -P root norm
mode = sys.argv[2]
scope_path = sys.argv[3]
include_logs = sys.argv[4] == "1"

WIKILINK_RE = re.compile(r"\[\[([^\]|]+)(\|[^\]]+)?\]\]")
# The SECOND grammar (additive): markdown links `[text](target)`. Harvested from
# code-stripped text only — a `](` inside a fence or inline code span is a
# documentation example, not a link (same stripping recipe as the R-48 hook and
# wikilink-repair). The wikilink scan above is deliberately untouched.
# DELIBERATE kernel deviation: the harvest requires the full `[text](target)`
# shape, not the kernel's bare `](target)` — a bare `](x)` sequence in prose
# (e.g. text DESCRIBING this very harvest) is not a link, and flagging it is a
# false positive a counter never had to care about but a finder does.
MDLINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")

def strip_code(text):
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'~~~[\s\S]*?~~~', '', text)
    text = re.sub(r'``[^`\n]+``', '', text)
    text = re.sub(r'`[^`\n]+`', '', text)
    return text

# Excluded dirs at walk level.
EXCLUDE_DIRS = {".git", ".obsidian", ".trash", "Archive"}
ORPHAN_EXCLUDE_BASENAMES = {"CLAUDE.md", "_index.md", "File-Index.md"}
# Meetings/, Daily/, Inbox/ are expected-orphan by design — generated content that
# does not receive inbound wikilinks (2026-04-22 finisher pass).
ORPHAN_EXCLUDE_DIRS_DEFAULT = {"Archive", "Logs", "Meetings", "Daily", "Inbox"} if not include_logs else {"Archive", "Meetings", "Daily", "Inbox"}

# Sources that legitimately CONTAIN wikilink-shaped strings pointing at broken
# targets because their purpose is auditing broken links elsewhere. Skip
# broken-link emission for these sources (structural false-positive fix —
# 2026-04-22 finisher pass). Still participates in inbound-link graph for
# orphan detection.
BROKEN_LINK_SOURCE_EXEMPT_PREFIXES = (
    "Logs/session-close-",
    "Logs/broken-wikilinks-",
    "Logs/wikilink-manual-triage-",
    "Logs/xref-",
)

# Plans/Projects/Skills/Wiki/Work are top-level symlink SURFACES the walker
# descends for link RESOLUTION only — their files STAY in target_map, so a
# vault-proper link pointing at a target that lives on one of these surfaces
# still resolves and is not falsely reported broken. They are NOT the vault-proper
# surface this cap governs, so emitting broken-link / orphan findings against a
# SOURCE that lives ON them is pure over-reach (0 true positives there). Exclude
# those surfaces from EMISSION only; keep them in the graph. Match the top-level
# path part (these are top-level mount points) so a genuinely-broken link in a
# vault-proper file is never wrongly suppressed.
SYMLINK_SURFACE_EXCLUDE = {"Plans", "Projects", "Skills", "Wiki", "Work"}

def on_symlink_surface(rel_parts):
    return bool(rel_parts) and rel_parts[0] in SYMLINK_SURFACE_EXCLUDE

# --- memory namespace: RESOLUTION ONLY, enumerated from disk at scan time ----------
# Returns the lowercased stems of every .md in the memory corpus. Used ONLY as a
# last-chance resolver for a target with ZERO vault candidates, so it can turn a
# false break into a resolution but can never mask a real one: a ref to a deleted
# memory finds no file, so it stays broken. Nothing here joins the vault graph.
def memory_namespace_stems():
    raw = os.environ.get("MEMORY_NS_ROOTS")
    if raw is not None:
        roots = [r for r in raw.split(os.pathsep) if r]
    else:
        home = os.environ.get("MEMORY_NS_HOME") or os.path.join(os.path.expanduser("~"), ".claude")
        roots = [os.path.join(home, "rules"), os.path.join(home, "memory")]
        try:
            projects = os.path.join(home, "projects")
            roots += [os.path.join(projects, d, "memory") for d in os.listdir(projects)]
        except OSError:
            pass
    stems = set()
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if not d.startswith(".")]
            for fn in fns:
                if fn.endswith(".md"):
                    stems.add(fn[:-3].lower())
    return stems

MEMORY_NS = memory_namespace_stems()

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

# Enumerate via the shared vault-view walker (file list at
# $XREF_WALK_LIST) so the graph descends the followed symlink view (2630 md) instead of
# os.walk followlinks=False (4 md). The walker skips dotdirs; EXCLUDE_DIRS (Archive etc.)
# are pruned here against the vault-relative path. FALL BACK to os.walk when the walker
# list is empty (symlink-inert floor).
walk_list_path = os.environ.get("XREF_WALK_LIST", "")
_walk_lines = []
if walk_list_path and os.path.isfile(walk_list_path):
    try:
        with open(walk_list_path) as _wf:
            _walk_lines = _wf.read().split("\n")
    except Exception:
        _walk_lines = []
# --- markdown-link resolution index (T-3) --------------------------
# Markdown targets are SOURCE-RELATIVE paths, resolved against the PHYSICAL
# directory of the source file (that is how every markdown consumer — an agent
# on disk, an editor, Obsidian — resolves them, and it is what makes a
# `../../<plan>/file.md` link from a symlink-mounted binder resolve correctly
# where a textual join against the LOGICAL path would not). The index is built
# ONCE from the same walk: every regular file (all extensions, resolution is
# existence, not governance) keyed by physical path, plus the ancestor-dir set
# for directory-style targets like `[name](name/)`. Per-link resolution is set
# membership — NO per-link stat(); os.path.realpath + one exists() fire only on
# an index MISS (a route crossing a symlink component, or a target outside the
# walked view), bounded by miss count, never by link count.
_real_dir_cache = {}
def _real_dirname(path_s):
    d = os.path.dirname(path_s)
    r = _real_dir_cache.get(d)
    if r is None:
        r = os.path.realpath(d)
        _real_dir_cache[d] = r
    return r

md_real_files = set()
md_real_dirs = set()
md_real_to_paths = {}   # physical path -> [Path] logical .md aliases in the graph
def _md_index_add(logical_s, p_obj):
    rp = os.path.join(_real_dirname(logical_s), os.path.basename(logical_s))
    md_real_files.add(rp)
    d = os.path.dirname(rp)
    while d and d != "/" and d not in md_real_dirs:
        md_real_dirs.add(d)
        d = os.path.dirname(d)
    if p_obj is not None:
        md_real_to_paths.setdefault(rp, []).append(p_obj)

def _mdlink_candidate(src_path_s, target_raw):
    """The proven kernel: drop absolute/~/anchor-only/URL targets, refuse
    unquoted whitespace (prose, not a link), strip #frag, %-decode, then
    normpath-join against the source's physical directory. Returns
    (candidate, is_dir) or None for a non-corpus reference."""
    t = target_raw.strip()
    if not t or t.startswith(("/", "~", "#", "http://", "https://", "mailto:")):
        return None
    if " " in t or "\t" in t or "\n" in t:
        return None
    t = t.split("#")[0]
    if not t:
        return None
    t = unquote(t)
    is_dir = t.endswith("/")
    cand = os.path.normpath(os.path.join(_real_dirname(src_path_s), t))
    return cand, is_dir

def _mdlink_resolve(cand, is_dir):
    if is_dir:
        if cand in md_real_dirs:
            return True
        return os.path.realpath(cand) in md_real_dirs or os.path.isdir(cand)
    if cand in md_real_files:
        return True
    if os.path.realpath(cand) in md_real_files:
        return True
    return os.path.exists(cand)

_used_walker = False
for line in _walk_lines:
    if not line:
        continue
    _md_index_add(line, None)
    if not line.endswith(".md"):
        continue
    p = Path(line)
    try:
        rel_parts = p.relative_to(vault).parts
    except ValueError:
        continue
    if any(part in EXCLUDE_DIRS or part.startswith(".") for part in rel_parts[:-1]):
        continue
    all_files.append(p)
    target_map.setdefault(p.stem.lower(), []).append(p)
    _md_index_add(line, p)
    _used_walker = True
if not _used_walker:
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith(".")]
        for fn in files:
            full = os.path.join(root, fn)
            _md_index_add(full, None)
            if not fn.endswith(".md"):
                continue
            p = Path(root) / fn
            all_files.append(p)
            target_map.setdefault(p.stem.lower(), []).append(p)
            _md_index_add(full, p)

# Build inbound-link graph + emit broken wikilink findings.
inbound = {p: 0 for p in all_files}
scoped_files = [p for p in all_files if in_scope(p)]

broken = 0
broken_mdlink = 0
people_oneway = 0
orphan = 0

findings = []

for src in scoped_files:
    try:
        text = src.read_text(errors="replace")
    except Exception:
        continue
    src_rel = str(src.relative_to(vault))
    # Exempt audit/report sources AND the top-level symlink surfaces from
    # broken-link emission — both still count inbound (cross-surface resolution is
    # unaffected); only emission against the surface is suppressed.
    exempt_src = any(src_rel.startswith(pref) for pref in BROKEN_LINK_SOURCE_EXEMPT_PREFIXES) \
        or on_symlink_surface(src.relative_to(vault).parts)
    for m in WIKILINK_RE.finditer(text):
        target_raw = m.group(1).strip()
        # Table-cell wikilinks use `\|` as escape for the cell divider:
        # `[[Target\|Display]]`. The regex `[^\]|]+` stops at the `|`, leaving
        # a trailing backslash on target_raw. Strip it before resolving.
        # (structural false-positive fix — 2026-04-22 finisher pass)
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
        elif key in MEMORY_NS:
            # Resolves in the memory corpus (outside the vault). Not broken, and NOT
            # graphed: it contributes no inbound count and never becomes an orphan
            # subject, so teaching the resolver cannot shift any other verdict.
            continue
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

    # Markdown-link branch (T-3, additive): resolve `[text](target)`
    # against the pre-built physical index. Resolved .md targets join the SAME
    # inbound graph (an md-link is an inbound edge for orphan detection);
    # broken ones emit xref-broken-mdlink under the SAME source exemptions and
    # symlink-surface emission suppression as the wikilink class.
    if "](" in text:
        for m in MDLINK_RE.finditer(strip_code(text)):
            res = _mdlink_candidate(str(src), m.group(1))
            if res is None:
                continue
            cand, is_dir = res
            if _mdlink_resolve(cand, is_dir):
                if not is_dir:
                    rp = cand if cand in md_real_files else os.path.realpath(cand)
                    for h in md_real_to_paths.get(rp, []):
                        inbound[h] = inbound.get(h, 0) + 1
                continue
            if exempt_src:
                continue
            findings.append({
                "finding": "xref-broken-mdlink",
                "file": src_rel,
                "target": m.group(1).strip(),
                "level": "error",
            })
            broken_mdlink += 1

# Bidirectional People check.
people_by_name = {}
for p in all_files:
    if "/People/" in str(p) and p.stem != "_index":
        people_by_name[p.stem.lower()] = p

# Physical-path join for markdown-grammar People references (T-3):
# an md-link target resolves to a physical path, so the People membership test
# for that grammar is keyed on the file's physical path, not its stem.
people_real = {}
for _nm, _pp in people_by_name.items():
    people_real[os.path.join(_real_dirname(str(_pp)), _pp.name)] = _nm

def _people_mdlink_refs(text, src_path_s):
    """Names of People files referenced by markdown links in text."""
    names = set()
    if "](" not in text:
        return names
    for m in MDLINK_RE.finditer(strip_code(text)):
        res = _mdlink_candidate(src_path_s, m.group(1))
        if res is None or res[1]:
            continue
        cand = res[0]
        rp = cand if cand in md_real_files else os.path.realpath(cand)
        nm = people_real.get(rp)
        if nm:
            names.add(nm)
    return names

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
    refs |= {nm for nm in _people_mdlink_refs(text, str(src_path)) if nm != src}
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
        back_refs |= _people_mdlink_refs(other_text, str(other_path))
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
    # Symlink surfaces are kept in the graph above for resolution but are not the
    # governed surface — skip orphan emission against them.
    if on_symlink_surface(rel.parts):
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
    "broken_mdlink": broken_mdlink,
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
    "broken_mdlink": doc.get("broken_mdlink", 0),
    "people_oneway": doc["people_oneway"],
    "orphan": doc["orphan"],
}
print(doc["broken"])
print(doc["orphan"])
print(doc["people_oneway"])
print(doc["total_files"])
print(doc["scoped_files"])
print(json.dumps(subtree))
print(doc.get("broken_mdlink", 0))   # appended AFTER the original six lines so their sed addresses stay stable
PY
)
BROKEN=$(echo "$SUMMARY" | sed -n '1p')
ORPHAN=$(echo "$SUMMARY" | sed -n '2p')
PEOPLE=$(echo "$SUMMARY" | sed -n '3p')
TOTAL=$(echo "$SUMMARY" | sed -n '4p')
SCOPED=$(echo "$SUMMARY" | sed -n '5p')
SUBTREE=$(echo "$SUMMARY" | sed -n '6p')
BROKEN_MD=$(echo "$SUMMARY" | sed -n '7p')

manifest_set '.xref_graph' "$SUBTREE"

# Report.
ISSUES=$((BROKEN + ${BROKEN_MD:-0} + PEOPLE))
printf "## Cross-References (%d issues)\n\n" "$ISSUES"
printf -- "- Files scanned: %d / %d total\n" "$SCOPED" "$TOTAL"
printf -- "- Broken wikilinks: %d\n" "$BROKEN"
printf -- "- Broken markdown links: %d\n" "${BROKEN_MD:-0}"
printf -- "- People one-way refs: %d\n" "$PEOPLE"
printf -- "- Orphans (info): %d\n" "$ORPHAN"
