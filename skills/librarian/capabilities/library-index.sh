#!/bin/bash
# library-index — KEYSTONE re-derive of the three-surface library indexes:
# per-topic `_library/<topic>/_index.md` and the library-root `_library/_index.md`,
# regenerated from article frontmatter on every run (type: index).
# Emits both tiers — the topic index and the root index — under the C-IDX index
# contract; consumes the routing one-liner (the per-article activation line that
# library-scrub.sh synthesizes).
#
# The library home resolves robustly the way sibling capabilities resolve the
# plans home — LIBRARY_DIR override, else $PLANS_DIR/_library (paths.sh), else
# $PLANS_ROOT/_library, never a hardcoded user-home literal.
#
# Re-derive discipline (C-IDX, mirrors index-maintain.sh's R-34 boundary):
#   In-bounds (regenerated each run): the sentinel-bounded contents-enum table
#     (rows: File markdown-link / Lines wc-l / Type frontmatter / Description
#     routing-first) and the `updated:` frontmatter date.
#   Out-of-bounds (survivorship-preserved verbatim): ALL prose outside the
#     sentinel markers — the H1, the 2-4-sentence folder-context paragraph, and
#     any other hand-authored content. The generator NEVER overwrites it; on a
#     first run it emits a placeholder folder-context paragraph for adopter fill.
#   parent_folder: is auto-populated from the dirname at depth >= 2 and verified
#     intact on every idempotent re-derive.
#
# C-IDX light-content fallback: a topic folder with fewer than 3 child .md files
#   of DISTINCT types emits a prose "Current Contents" section INSTEAD of the
#   sentinel table.
#
# root index: one row per topic; the topic Description is the topic-scope
#   activation line synthesized by AGGREGATING member-article routing: fields
#   (1:many) — NOT the per-row single-file derivation chain. Each topic row carries
#   the topic's staleness date read from _library/log.md's last entry for that
#   topic (log.md is owned by a separate capability; absent => empty column; the
#   first run is valid with no log).
#
# Findings (audit-time scan, NEVER a write-time guard):
#   library-article-over-threshold  an article exceeds the soft length budget
#     (size_limits read from governance/file-type-contracts/library-article.md.json
#     when present, else the SoT constants {400 soft, 800 hard}).
#   library-basename-collision      two files share a basename (breaks bare-
#     wikilink resolution; a load-bearing component of the library contract).
#   library-duplicate-title         two articles carry near-duplicate H1/title
#     (needs reconciliation before bare-wikilink resolution is deterministic).
#   library-broken-link             a dangling wikilink/path, OR a one-sided
#     originating_plan/manifest library_refs edge — the promotion crash-window DETECTOR
#     role: a promotion interrupted between the article write and the manifest-edge
#     write leaves a one-sided edge; this capability detects + reports it and NEVER
#     repair-writes the edge.
#   library-article-body-shape      an article carries a leading in-document
#     section index or an auto-generated TOC under the soft budget (the
#     body-shape; advisory finding routed here per the owner-pick).
#
# Output Contract (per CLAUDE.md skill-creation rule):
#   Files written (--query mode: NONE — it is a pure read surface; it prints a
#     topic's _index.md (or an available-topics list) to stdout and performs ZERO
#     file writes, no findings emission, no manifest touch):
#     - {LIBRARY}/<topic>/_index.md  bounded to the
#         <!-- contents-enum:start --> ... <!-- contents-enum:end --> sentinel
#         region + the `updated:` frontmatter line (survivorship: all prose
#         outside the sentinels — H1, folder-context paragraph — preserved
#         verbatim; light-content topics get a prose "Current Contents" section
#         in place of the table).
#     - {LIBRARY}/_index.md          the root topic-roster index (same sentinel +
#         updated: bounded write).
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: governance/file-type-contracts/_index.md.json (the C-IDX
#     body-structure + frontmatter contract every generated _index.md conforms
#     to); the library-article size_limits source is
#     governance/file-type-contracts/library-article.md.json when present.
#   Pre-write validation:
#     - the library home must resolve to a directory (absent => block-and-log,
#       no write, exit 0 — never crash, defensive-default class).
#     - every generated _index.md carries valid C-IDX frontmatter (type=index,
#       non-empty tags, ISO updated, parent_folder at depth >= 2) BEFORE write.
#     - atomic temp-file + os.replace; the sentinel region is the ONLY mutated
#       body span (plus updated:).
#   Failure mode: BLOCK-AND-LOG. A topic that cannot be rendered emits a finding
#     and is skipped; no partial write. Never write-and-hope.
#   Maintainer-provenance: _index.md is a librarian-maintained artifact
#     (maintainer=librarian); this capability is its sole
#     originating writer. It NEVER writes articles, _raw/, or log.md (other
#     maintainers own those) and NEVER repairs a one-sided PROMO-4 edge.
#
# CLI:
#   library-index.sh                 # re-derive every topic index + the root index
#   library-index.sh --topic <name>  # re-derive one topic index (+ the root)
#   library-index.sh --dry-run       # findings + would-be writes, NO file write
#   library-index.sh --query <topic> # READ-ONLY: print one topic's _index.md to
#                                       stdout (resolves exact topic name first,
#                                       then case-insensitive/fuzzy prefix match);
#                                       topic/library absent -> a short available-
#                                       topics list. ZERO writes; exit 0. This is
#                                       the executable target of the
#                                       at-cap pointer pre-research-check.sh emits.
#   library-index.sh --help
#
# Env overrides (testing):
#   LIBRARY_DIR     library home (default: $PLANS_DIR/_library -> $PLANS_ROOT/_library)
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh)
#   GOVERNANCE_DIR  governance root (default: $CLAUDE_HOME/governance -> repo governance)
#   PLAN_MANIFEST_GLOB_ROOT  root walked for manifest library_refs[] (one-sided-edge
#                   detection); default: PLANS_ROOT. (test isolation)
#   FINDINGS_OUTPUT NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

DRY_RUN="false"
TOPIC_FILTER=""
QUERY_MODE="false"
QUERY_TOPIC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --topic)   TOPIC_FILTER="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --query)   QUERY_MODE="true"; QUERY_TOPIC="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,103p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "library-index: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- library home resolution (robust; the sibling plans-home pattern) --------
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
LIBRARY="${LIBRARY_DIR:-${PLANS_DIR:-$PLANS_ROOT}/_library}"
case "$LIBRARY" in */) LIBRARY="${LIBRARY%/}" ;; esac
MANIFEST_ROOT="${PLAN_MANIFEST_GLOB_ROOT:-$PLANS_ROOT}"

# --- --query: READ-ONLY topic-index print (pointer target) -------
# Pure read surface for the three-load selectivity chain (root index -> topic
# index -> article): resolve the topic (exact dir-name match first, then a
# case-insensitive / fuzzy prefix match), print that topic's _index.md to stdout,
# exit 0. ZERO file writes, no findings emission, no manifest walk. Topic-absent
# or library-absent -> a short available-topics list (or a graceful message),
# exit 0. This branch returns BEFORE any generation logic runs.
if [ "$QUERY_MODE" = "true" ]; then
  python3 - "$LIBRARY" "$QUERY_TOPIC" <<'PY'
import os, re, sys

library, query = sys.argv[1:3]
query = (query or "").strip()

def _has_article(full):
    # article-bearing test — >=1 nested-inclusive article .md
    # (excludes _index.md, dotfiles, and the _raw/ provenance subtree). Mirrors the
    # generation-block topic_articles predicate so the --query lister and the generated
    # index agree on which underscore-topic dirs are real topics.
    for dp, dns, fns in os.walk(full):
        dns[:] = [x for x in dns if x != "_raw" and not x.startswith(".")]
        for fn in fns:
            if fn.endswith(".md") and fn != "_index.md" and not fn.startswith("."):
                return True
    return False

def list_topics(lib):
    topics = []
    try:
        for d in sorted(os.listdir(lib)):
            full = os.path.join(lib, d)
            if not os.path.isdir(full) or d.startswith(".") or d == "log-archive" or d == "_raw":
                continue
            # underscore-topic dirs are listed only when article-bearing (careful predicate).
            if d.startswith("_") and not _has_article(full):
                continue
            topics.append(d)
    except Exception:
        pass
    return topics

# library home absent -> graceful message, exit 0, no crash.
if not library or not os.path.isdir(library):
    sys.stdout.write("library-index --query: no library at %s — nothing to query.\n"
                     % (library or "(unset)"))
    sys.exit(0)

topics = list_topics(library)

def print_available(reason=""):
    if reason:
        sys.stdout.write(reason + "\n")
    if topics:
        sys.stdout.write("Available topics:\n")
        for t in topics:
            sys.stdout.write("  - %s\n" % t)
        sys.stdout.write("\nRun: librarian library-index --query <topic>\n")
    else:
        sys.stdout.write("The library has no topics yet.\n")

# no topic given -> just list what's available.
if not query:
    print_available("library-index --query: no topic given.")
    sys.exit(0)

# --- resolve the topic --------------------------------------------------------
resolved = None
# 1) exact topic-dir name match
if query in topics:
    resolved = query
# 2) case-insensitive exact match
if resolved is None:
    ql = query.lower()
    for t in topics:
        if t.lower() == ql:
            resolved = t
            break
# 3) case-insensitive prefix match (fuzzy), unambiguous-first then first-sorted
if resolved is None:
    ql = query.lower()
    prefix = [t for t in topics if t.lower().startswith(ql)]
    if not prefix:
        # 4) case-insensitive substring (looser fuzzy) as a last resort
        prefix = [t for t in topics if ql in t.lower()]
    if len(prefix) == 1:
        resolved = prefix[0]
    elif len(prefix) > 1:
        sys.stdout.write("library-index --query: '%s' matches multiple topics:\n" % query)
        for t in prefix:
            sys.stdout.write("  - %s\n" % t)
        sys.stdout.write("\nRe-run with a more specific topic name.\n")
        sys.exit(0)

if resolved is None:
    print_available("library-index --query: no topic matches '%s'." % query)
    sys.exit(0)

# --- print the resolved topic's _index.md (read-only) -------------------------
idx = os.path.join(library, resolved, "_index.md")
if not os.path.isfile(idx):
    sys.stdout.write("library-index --query: topic '%s' has no _index.md yet "
                     "(run library-index to generate it).\n" % resolved)
    sys.exit(0)
try:
    with open(idx, encoding="utf-8") as fh:
        sys.stdout.write(fh.read())
except Exception as exc:
    sys.stdout.write("library-index --query: could not read %s (%s).\n" % (idx, exc))
sys.exit(0)
PY
  exit 0
fi

# --- governance resolution ---------------------------------------------------
GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ]; then
  for cand in "$CLAUDE_HOME_RES/governance" "$_REPO_ROOT/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi
FM_RULES="$GOV_DIR/frontmatter-rules.json"
# library-article size_limits contract: emitted later by the template unit at
# exactly this path; absent today -> the SoT constants {400 soft, 800 hard}.
ART_CONTRACT="$GOV_DIR/file-type-contracts/library-article.md.json"

# Canonical governance read: the Type-column enum is the EFFECTIVE
# type registry, so route the read through the R-52 union-load merger
# (hooks/lib/foundation-overlay-load.sh) — never consume foundation-master /
# frontmatter-rules.json RAW. Resolve the SHIPPED bundle, materialize the merged
# union once (full-union: same top-level shape as foundation-master), and pass it
# to the python3 body, which reads .frontmatter.types from the merged view so an
# adopter's overlay-master.json amendments are honored. The loose pillar FM_RULES
# (.types shape) stays as the dev-repo/no-bundle fallback (loud-safe, never broken).
FM_BUNDLE=""
for cand in "$CLAUDE_HOME_RES/governance/foundation-master.json" \
            "$GOV_DIR/foundation-master.json"; do
  [ -f "$cand" ] && { FM_BUNDLE="$cand"; break; }
done
_OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
[ -x "$_OVL" ] || _OVL="$_REPO_ROOT/hooks/lib/foundation-overlay-load.sh"
if [ -x "$_OVL" ] && [ -n "$FM_BUNDLE" ] && [ -f "$FM_BUNDLE" ]; then
  _UNION="$(mktemp 2>/dev/null || true)"
  if [ -n "$_UNION" ] && bash "$_OVL" --foundation-path "$FM_BUNDLE" \
        --overlay-path "$(dirname "$FM_BUNDLE")/overlay-master.json" --force-override > "$_UNION" 2>/dev/null \
        && [ -s "$_UNION" ]; then
    FM_BUNDLE="$_UNION"; trap 'rm -f "$_UNION"' EXIT
  elif [ -n "$_UNION" ]; then rm -f "$_UNION"; fi
fi

LOG_MD="$LIBRARY/log.md"   # owned by a separate capability; read-when-present.

python3 - "$LIBRARY" "$FM_RULES" "$ART_CONTRACT" "$LOG_MD" "$MANIFEST_ROOT" "$DRY_RUN" "$TOPIC_FILTER" "$FM_BUNDLE" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

library, fm_rules_path, art_contract_path, log_md_path, manifest_root, dry_s, topic_filter = sys.argv[1:8]
fm_bundle_path = sys.argv[8] if len(sys.argv) > 8 else ""
dry_run = (dry_s == "true")
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")

START = "<!-- contents-enum:start -->"
END = "<!-- contents-enum:end -->"
PLACEHOLDER = ("*[Folder context paragraph: 2-4 sentences describing what lives "
               "here, what doesn't, why the folder exists. Pedagogical.]*")

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# --- block-and-log: the library home must resolve ---------------------------
if not library or not os.path.isdir(library):
    emit({"finding": "library-index-blocked", "file": library or "(unset)",
          "reason": "library-home-absent", "detected_at": today})
    print("library-index: library home absent (%s); nothing to index" % (library or "(unset)"),
          file=sys.stderr)
    sys.exit(0)

# --- size_limits: contract-when-present, else SoT constants -----------------
soft_max, hard_max = 400, 800
if os.path.isfile(art_contract_path):
    try:
        with open(art_contract_path, encoding="utf-8") as fh:
            sl = (json.load(fh).get("size_limits") or {})
        if isinstance(sl.get("max_lines"), int):
            soft_max = sl["max_lines"]
        if isinstance(sl.get("soft"), int):
            soft_max = sl["soft"]
        if isinstance(sl.get("hard"), int):
            hard_max = sl["hard"]
    except Exception:
        pass

# --- Type-column enum source: the EFFECTIVE type registry (non-_-prefixed) ----
# canonical read: the merged union (foundation-master + overlay) is
# materialized by the merger in the shell wrapper and handed in as fm_bundle_path
# (.frontmatter.types shape). Read it FIRST so an adopter's overlay amendments to
# the type registry are honored; fall back to the loose pillar (.types shape) when
# the bundle/merger is unavailable (dev-repo authoring or explicit FM_RULES).
type_enum = set()
if fm_bundle_path and os.path.isfile(fm_bundle_path):
    try:
        with open(fm_bundle_path, encoding="utf-8") as fh:
            types = ((json.load(fh).get("frontmatter") or {}).get("types") or {})
        type_enum = {k for k in types.keys() if not k.startswith("_")}
    except Exception:
        type_enum = set()
if not type_enum and os.path.isfile(fm_rules_path):
    try:
        with open(fm_rules_path, encoding="utf-8") as fh:
            types = (json.load(fh).get("types") or {})
        type_enum = {k for k in types.keys() if not k.startswith("_")}
    except Exception:
        type_enum = set()

# reference-type REQUIRED set for audit-time frontmatter conformance —
# the SAME set library-scrub validates at write-time (its canonical merged-union read); here it
# catches a POST-write field drop the write-time gate cannot see. Merged-bundle FIRST (adopter
# overlay honored), then the loose pillar, then the SoT constants (mirrors library-scrub).
REF_REQUIRED = ["type", "tags", "updated", "routing", "sources", "originating_plan",
                "description", "created", "id", "schema_version"]
_ref_c = None
if fm_bundle_path and os.path.isfile(fm_bundle_path):
    try:
        with open(fm_bundle_path, encoding="utf-8") as fh:
            _ref_c = ((json.load(fh).get("frontmatter") or {}).get("types") or {}).get("reference")
    except Exception:
        _ref_c = None
if not (_ref_c and _ref_c.get("required")) and os.path.isfile(fm_rules_path):
    try:
        with open(fm_rules_path, encoding="utf-8") as fh:
            _ref_c = (json.load(fh).get("types") or {}).get("reference")
    except Exception:
        _ref_c = None
if _ref_c and isinstance(_ref_c.get("required"), list) and _ref_c["required"]:
    REF_REQUIRED = _ref_c["required"]

# --- frontmatter parser (mirrors index-maintain.sh) -------------------------
def parse_fm(text):
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    fm = {}
    for line in text[3:end].splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if m:
            fm[m.group(1)] = m.group(2)
    return fm

def read_head(path, n=4096):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read(n)
    except Exception:
        return ""

def read_all(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return ""

def line_count(path):
    try:
        with open(path, "rb") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0

def first_h1(text):
    for line in text.splitlines():
        m = re.match(r"^#\s+(.*\S)\s*$", line)
        if m:
            return m.group(1).strip()
    return ""

def first_paragraph(text):
    # first non-frontmatter, non-heading, non-blank line block
    body = text
    if body.startswith("---"):
        e = body.find("\n---", 3)
        if e != -1:
            body = body[e + 4:]
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("|"):
            continue
        return line
    return ""

def derive_description(fm, text):
    # C-IDX derivation chain, routing-first (priority-ordered EXTENSION of the
    # shipped description: -> H1 -> first-paragraph fallback).
    for key in ("routing", "description"):
        v = (fm.get(key) or "").strip()
        if v:
            return v[:200]
    v = first_h1(text)
    if v:
        return v[:200]
    v = first_paragraph(text)
    return v[:200] if v else ""

def has_inline_toc(text):
    # body shape: a leading in-document section index / auto-generated
    # TOC. Detect an explicit "## Contents" / "## Table of Contents" heading or a
    # "- [text](#anchor)" anchor-link block near the top of the body.
    body = text
    if body.startswith("---"):
        e = body.find("\n---", 3)
        if e != -1:
            body = body[e + 4:]
    head = "\n".join(body.splitlines()[:40])
    if re.search(r"(?im)^#{1,3}\s+(table of contents|contents|toc)\s*$", head):
        return True
    anchor_links = re.findall(r"^\s*[-*]\s+\[[^\]]+\]\(#[^)]+\)", head, re.M)
    return len(anchor_links) >= 3

def md_target(t):
    # minimal percent-quoting so a markdown link target survives spaces/parens
    return t.replace(" ", "%20").replace("(", "%28").replace(")", "%29")

def render_row(name, target, lines, ftype, desc):
    # File cell: `.md`-suffixed label + relative markdown link per the shipped
    # _index.md.json File column (value_type markdown-link; one link grammar).
    # `name` is the basename without .md; `target` is the topic-relative path
    # (nested articles link their subdir-relative path).
    ln = "~%d" % lines if isinstance(lines, str) else "%d" % lines
    if isinstance(lines, str):
        ln = lines
    return "| [%s.md](%s) | %s | %s | %s |" % (name, md_target(target), ln, ftype or "—", desc.replace("|", "\\|"))

# --- topic scan -------------------------------------------------------------
def topic_articles(topic_dir):
    """Return list of (name, path, fm, text) for article .md files UNDER a topic.
    RECURSE nested subdirs (was: flat os.listdir at the topic
    root) while PRESERVING the intentional exclusions — _index.md, dotfiles, and the
    _raw/ article-provenance subtree stay excluded (a careful predicate, NOT a blanket
    include). `name` stays the basename so the render + basename-collision semantics for
    root articles are byte-unchanged; a nested article surfaces by its own basename."""
    arts = []
    for dirpath, dirnames, filenames in os.walk(topic_dir):
        dirnames[:] = [d for d in dirnames if d != "_raw" and not d.startswith(".")]
        for f in sorted(filenames):
            if not f.endswith(".md") or f == "_index.md" or f.startswith("."):
                continue
            p = os.path.join(dirpath, f)
            if not os.path.isfile(p):
                continue
            text = read_all(p)
            arts.append((f[:-3], p, parse_fm(text), text))
    return arts

def write_atomic(dirpath, target, body):
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._index.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, target)

def splice_index(idx_path, dirpath, folder_name, parent_folder, default_tags,
                 inner_block, light_prose=None):
    """Generate or re-derive an _index.md: survivorship-preserve all prose outside
    the sentinel region; regenerate the table (or replace it with light prose);
    bump updated:. Returns the rendered text (also writes unless dry_run)."""
    existing = read_all(idx_path) if os.path.isfile(idx_path) else ""

    if existing:
        # --- re-derive: preserve everything outside the sentinels ------------
        fm = parse_fm(existing)
        # frontmatter survivorship + mechanical refresh (updated:, parent_folder)
        text = existing
        # ensure parent_folder present at depth >= 2 (verified on idempotent regen)
        if parent_folder and "parent_folder" not in fm:
            text = re.sub(r"(?m)^type:\s*index\s*$",
                          "type: index\nparent_folder: %s" % parent_folder, text, count=1)
        # bump updated:
        if re.search(r"(?m)^updated:", text):
            text = re.sub(r"(?m)^updated:.*$", "updated: %s" % today, text, count=1)
        s = text.find(START)
        e = text.find(END)
        if light_prose is not None:
            # light-content: the table is replaced by prose. If a sentinel region
            # exists, collapse it to the prose; else leave the body's prose as-is
            # but ensure the prose section is present (idempotent).
            if s >= 0 and e > s:
                text = text[:s] + light_prose.rstrip() + "\n" + text[e + len(END):]
            elif "## Current Contents" not in text:
                text = text.rstrip() + "\n\n" + light_prose.rstrip() + "\n"
        else:
            if s >= 0 and e > s:
                text = text[:s + len(START)] + "\n\n" + inner_block + "\n\n" + text[e:]
            else:
                # no sentinel region in a hand-authored file: append a fresh one
                # without touching the existing prose (survivorship).
                text = text.rstrip() + "\n\n" + START + "\n\n" + inner_block + "\n\n" + END + "\n"
        rendered = text
    else:
        # --- first run: scaffold (placeholder folder-context paragraph) -------
        fm_lines = ["---", "type: index"]
        if parent_folder:
            fm_lines.append("parent_folder: %s" % parent_folder)
        fm_lines += ["tags: [%s]" % default_tags, "updated: %s" % today, "---", ""]
        head = "\n".join(fm_lines)
        head += "# %s\n\n%s\n\n" % (folder_name, PLACEHOLDER)
        if light_prose is not None:
            rendered = head + light_prose.rstrip() + "\n"
        else:
            rendered = head + START + "\n\n" + inner_block + "\n\n" + END + "\n"

    if not dry_run:
        try:
            write_atomic(dirpath, idx_path, rendered)
        except Exception as exc:
            emit({"finding": "library-index-blocked", "file": idx_path,
                  "reason": "write-failed", "error": str(exc), "detected_at": today})
            return None
    return rendered

# --- cross-cutting: manifest library_refs[] for one-sided-edge detection -----
def collect_manifest_refs(root):
    """Map library_ref string -> set(plan-slug) declared in manifests under root."""
    refs = {}
    if not os.path.isdir(root):
        return refs
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if not d.startswith(".")]
        if "manifest.json" not in fns:
            continue
        mp = os.path.join(dp, "manifest.json")
        try:
            with open(mp, encoding="utf-8") as fh:
                man = json.load(fh)
        except Exception:
            continue
        slug = os.path.basename(dp)
        ras = man.get("research_artifacts") or []
        if isinstance(ras, list):
            for ra in ras:
                if not isinstance(ra, dict):
                    continue
                for lr in (ra.get("library_refs") or []):
                    refs.setdefault(str(lr).strip(), set()).add(slug)
    return refs

manifest_refs = collect_manifest_refs(manifest_root)

# --- staleness: parse log.md last-entry-per-topic when present --------------
def topic_staleness(log_path):
    """topic -> ISO date from the LAST log.md line that names that topic's path.
    log.md format: `YYYY-MM-DDTHH:MM:SSZ [ACTION] <path> — <note>`."""
    st = {}
    if not os.path.isfile(log_path):
        return st
    for raw in read_all(log_path).splitlines():
        m = re.match(r"^(\d{4}-\d{2}-\d{2})T[0-9:]+Z?\s+\[[A-Z]+\]\s+(\S+)", raw)
        if not m:
            continue
        d, path = m.group(1), m.group(2)
        seg = path.strip("/").split("/")
        topic = seg[0] if seg else ""
        if topic:
            st[topic] = d  # last write wins (chronological append order)
    return st

staleness = topic_staleness(log_md_path)

# --- enumerate topics --------------------------------------------------------
all_basenames = {}   # basename -> [paths]  (library-wide basename-collision)
all_titles = {}      # normalized-title -> [ (article-path, title) ]

topic_dirs = []
for d in sorted(os.listdir(library)):
    full = os.path.join(library, d)
    if not os.path.isdir(full) or d.startswith(".") or d == "log-archive" or d == "_raw":
        continue
    # an underscore-prefixed dir is a real TOPIC only when it is
    # article-bearing (>=1 nested-inclusive article .md, _raw/_index excluded); a bare
    # infra dir (no articles) stays dropped — a careful predicate, NOT a blanket
    # underscore-allow (the underscore-topic articles were previously invisible).
    if d.startswith("_") and not topic_articles(full):
        continue
    topic_dirs.append(d)

# library-wide article basename set so a valid CROSS-TOPIC
# [[topic/name]] resolves against the WHOLE library (not just the current topic dir). The
# resolver stripped to basename + checked only the current topic, false-flagging every valid
# cross-topic link. Collected ONCE up front (the per-article broken-link check runs per topic).
lib_basenames = set()
for _lt in topic_dirs:
    for _ln, _lp, _lfm, _ltx in topic_articles(os.path.join(library, _lt)):
        lib_basenames.add(_ln)

root_rows = []          # (topic, lines, type, aggregated-routing-desc, staleness)
topics_indexed = 0

for topic in topic_dirs:
    if topic_filter and topic != topic_filter:
        # still need its data for the root index; gather but don't write its index
        pass
    topic_dir = os.path.join(library, topic)
    arts = topic_articles(topic_dir)

    # collect basenames + titles library-wide (collision + dup-title findings)
    for name, p, fm, text in arts:
        all_basenames.setdefault(name, []).append(p)
        title = (first_h1(text) or name).strip().lower()
        title = re.sub(r"\s+", " ", title)
        all_titles.setdefault(title, []).append((p, first_h1(text) or name))

    # per-article findings: over-threshold + body-shape + broken/one-sided edge
    routing_lines = []
    for name, p, fm, text in arts:
        # audit-time REF_REQUIRED conformance — scoped to declared
        # type:reference articles, by KEY PRESENCE (a multi-line list value like sources: parses
        # to an empty string but the KEY is present, so it is not false-flagged). Real library
        # articles are heterogeneous, so only declared-reference articles are held to the
        # reference contract; a POST-write required-field drop now surfaces (was: write-time only).
        if (fm.get("type") or "").strip() == "reference":
            _miss = [k for k in REF_REQUIRED if k not in fm]
            if _miss:
                emit({"finding": "library-article-frontmatter-nonconformant", "file": p,
                      "missing_fields": _miss, "contract": "reference",
                      "reason": "reference article frontmatter missing required field(s): %s "
                                "(validated only at write-time before this audit)" % ",".join(_miss),
                      "detected_at": today})
        # resolve REQUIRED sources:[_raw/<x>] provenance pointers. A
        # deleted _raw target dangled undetected (the broken-link arm resolved only wikilinks +
        # PROMO-4). Extract _raw/<x> tokens from the frontmatter block (robust to multi-line YAML
        # lists) and resolve against the topic dir.
        _fm_block = ""
        if text.startswith("---"):
            _fe = text.find("\n---", 3)
            if _fe != -1:
                _fm_block = text[3:_fe]
        for _rawref in re.findall(r"_raw/[^\s\"'\],]+", _fm_block):
            _rawref = _rawref.rstrip(".")
            if not os.path.isfile(os.path.join(topic_dir, _rawref)):
                emit({"finding": "library-broken-link", "file": p,
                      "issue": "dangling-raw-source", "target": _rawref,
                      "detector_role": "REF-sources-provenance", "detected_at": today})
        lc = line_count(p)
        if lc > soft_max:
            emit({"finding": "library-article-over-threshold", "file": p,
                  "lines": lc, "soft_budget": soft_max, "hard_budget": hard_max,
                  "severity": "warn" if lc <= hard_max else "error",
                  "detected_at": today})
        if lc <= soft_max and has_inline_toc(text):
            emit({"finding": "library-article-body-shape", "file": p,
                  "issue": "leading-in-document-section-index-or-auto-toc-under-soft-budget",
                  "soft_budget": soft_max, "detected_at": today})
        # one-sided PROMO-4 edge: article declares originating_plan but the
        # manifest's library_refs[] does not point back (or vice versa).
        ref_key = "%s/%s" % (topic, name)
        op = (fm.get("originating_plan") or "").strip()
        back = manifest_refs.get(ref_key) or manifest_refs.get("%s/%s.md" % (topic, name)) or set()
        if op and op not in back:
            emit({"finding": "library-broken-link", "file": p,
                  "issue": "one-sided-promo4-edge", "originating_plan": op,
                  "library_ref": ref_key, "manifest_backlinks": ",".join(sorted(back)) or "(none)",
                  "detector_role": "promotion-edge-crash-window", "detected_at": today})
        # dangling bare wikilinks at the article foot -> sibling that does not exist
        for wl in re.findall(r"\[\[([^\[\]|]+?)\]\]", text):
            base = wl.split("/")[-1]
            base = base[:-3] if base.endswith(".md") else base
            sib = os.path.join(topic_dir, base + ".md")
            # resolve library-wide. A valid CROSS-TOPIC [[topic/name]]
            # whose basename exists ANYWHERE in the library is NOT dangling (was: current-topic
            # dir only -> every valid cross-topic link false-flagged). Only a basename present
            # NOWHERE (current-topic sibling / current-topic arts / library-wide) dangles.
            if (not os.path.isfile(sib)
                    and base not in [a[0] for a in arts]
                    and base not in lib_basenames):
                emit({"finding": "library-broken-link", "file": p,
                      "issue": "dangling-wikilink", "target": wl,
                      "detected_at": today})
        rt = (fm.get("routing") or "").strip()
        if rt:
            routing_lines.append(rt)

    # distinct types among children (light-content fallback gate)
    distinct_types = set()
    for name, p, fm, text in arts:
        t = (fm.get("type") or "").strip()
        if t:
            distinct_types.add(t)
    light = len(arts) < 3 and len(distinct_types) < 3

    # build topic index inner block
    folder_name = topic
    # parent_folder (contract shape): the indexed folder's PARENT, root-relative in
    # this walker's frame (the plans root — the plans tree's canonical address
    # family is the physical one). The library root is top-level there, so its
    # basename IS its root-relative path: this emission is already the ruled shape.
    parent_folder = os.path.basename(library)   # depth >= 2: <library>/<topic>/_index.md
    # tags item-pattern: ^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$
    tag_topic = re.sub(r"[^a-z0-9-]", "-", topic.lower()).strip("-") or "topic"
    default_tags = '"#library/%s"' % tag_topic

    if light:
        # prose "Current Contents" section INSTEAD of the table
        prose = ["## Current Contents", ""]
        if arts:
            for name, p, fm, text in arts:
                desc = derive_description(fm, text)
                tgt = md_target(os.path.relpath(p, topic_dir))
                prose.append("- [%s](%s) — %s" % (name, tgt, desc) if desc else "- [%s](%s)" % (name, tgt))
        else:
            prose.append("_No articles yet._")
        prose.append("")
        idx_inner = None
        light_prose = "\n".join(prose)
    else:
        hdr = "| File | Lines | Type | Description |\n|---|---|---|---|"
        rows = []
        for name, p, fm, text in arts:
            ftype = (fm.get("type") or "").strip()
            if ftype and type_enum and ftype not in type_enum:
                ftype = ftype  # keep the declared value; enum is advisory for render
            desc = derive_description(fm, text)
            rows.append(render_row(name, os.path.relpath(p, topic_dir), line_count(p), ftype, desc))
        idx_inner = hdr + "\n" + ("\n".join(rows) if rows else "")
        light_prose = None

    if not (topic_filter and topic != topic_filter):
        idx_path = os.path.join(topic_dir, "_index.md")
        splice_index(idx_path, topic_dir, folder_name, parent_folder,
                     default_tags, idx_inner, light_prose=light_prose)
        topics_indexed += 1

    # root-index row: aggregate member routing (1:many) into a topic-scope line
    if routing_lines:
        # synthesize a topic-scope activation line by aggregating member routing:
        agg = "; ".join(dict.fromkeys(rl.rstrip(".") for rl in routing_lines))
        agg = ("Read for: " + agg)[:200]
    else:
        agg = ""
    root_rows.append((topic, len(arts), staleness.get(topic, ""), agg))

# --- library-wide basename-collision + duplicate-title findings -------------
for base, paths in all_basenames.items():
    if len(paths) > 1:
        emit({"finding": "library-basename-collision", "file": base + ".md",
              "colliding_paths": ",".join(sorted(paths)), "count": len(paths),
              "issue": "bare-wikilink-resolution-ambiguous", "detected_at": today})
for title, entries in all_titles.items():
    if len(entries) > 1:
        # WHY this is a finding: duplicate titles need reconciliation before bare-
        # wikilink resolution is deterministic. duplicate_paths names every colliding
        # article so the operator can pick the survivor.
        emit({"finding": "library-duplicate-title", "file": entries[0][0],
              "title": entries[0][1], "duplicate_paths": ",".join(sorted(e[0] for e in entries)),
              "count": len(entries), "detected_at": today})

# --- root _index.md ---------------------------------------------------------
# one row per topic; Description = aggregated member routing; each row
# carries the topic's staleness date (empty when no log.md). Columns reuse the
# C-IDX shape; the Topic cell is a markdown link to the topic's _index.md.
root_hdr = "| Topic | Articles | Type | Description |\n|---|---|---|---|"
root_table_rows = []
for topic, n, stale, agg in sorted(root_rows):
    desc = agg
    if stale:
        desc = (desc + (" " if desc else "") + ("(updated %s)" % stale)).strip()[:200]
    root_table_rows.append("| [%s](%s/_index.md) | %d | index | %s |" % (topic, md_target(topic), n, desc.replace("|", "\\|")))

if not root_rows:
    # light-content root: no topics yet
    root_light = "## Current Contents\n\n_No topics yet._\n"
    splice_index(os.path.join(library, "_index.md"), library, os.path.basename(library),
                 "", '"#library/root"', None, light_prose=root_light)
else:
    root_inner = root_hdr + "\n" + "\n".join(root_table_rows)
    splice_index(os.path.join(library, "_index.md"), library, os.path.basename(library),
                 "", '"#library/root"', root_inner, light_prose=None)

print("library-index: topics_indexed=%d root_rows=%d dry_run=%s"
      % (topics_indexed, len(root_rows), dry_run), file=sys.stderr)
PY
