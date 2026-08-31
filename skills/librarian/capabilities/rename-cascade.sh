#!/bin/bash
# rename-cascade — Apply rename cascade: update inbound wikilinks (and
# optionally frontmatter path refs) when a file has been renamed.
#
# Pipe-composable downstream of
# rename-detect.sh:
#
#   rename-detect.sh | rename-cascade.sh                 # dry-run
#   rename-detect.sh | rename-cascade.sh --apply         # writes changes
#   rename-detect.sh | rename-cascade.sh --include-frontmatter
#
# Behavior:
#   For each stdin NDJSON record { old_path, new_path, ... }:
#     1. Wikilink-mode (always): scan vault + plans for inbound
#        [[<old_basename>]], [[<old_basename>|alias]], [[<old_basename>#heading]]
#        (with or without .md suffix). Propose replacement to new_basename.
#     1b. Markdown-link REWRITE (always): an inbound `[text](relative/target)`
#        whose physical candidate matches the renamed old_path is rewritten to
#        the SOURCE-FILE-RELATIVE path of new_path (emits
#        `rename-cascade-mdlink`). The arithmetic is the load-bearing part:
#        rename records carry REPO-ROOT-RELATIVE paths while a markdown link
#        is source-file-relative, so the target is resolved against
#        dirname(source), compared against join(root, old_path), and
#        re-rendered as relpath(join(root, new_path), dirname(source)) — a
#        naive substring replace mis-repairs at any depth. %-quoting and
#        #anchor tails are preserved; fenced blocks and inline code spans are
#        never rewritten (a link there is a quotation).
#     2. Frontmatter-mode (--include-frontmatter): also scan .md frontmatter
#        for path-valued keys (spec_path, handoff_path, ideation_brief_path,
#        tasks_path) equal to old_path. Propose path update.
#     3. parent_plan: slug mode (inside --include-frontmatter): when a plan
#        directory is renamed (e.g. `67-old/` -> `67-new/`, child file shows
#        up as old_path=67-old/<file> new_path=67-new/<file>), derive the
#        slug pair (strip leading NN- prefix) and rewrite child-file
#        `parent_plan: <old-slug>` values to `parent_plan: <new-slug>`.
#        Scope-guard: only acts when the renamed path is under $PLANS_DIR.
#
# Flags:
#   --apply                         default is dry-run; writes files
#   --include-frontmatter           enable frontmatter path-ref + parent_plan
#   --scope <path>                  override scan root (repeatable)
#   --from-history                  ALSO load rename records from the
#                                   librarian-manifest rename_history[]
#                                   (populated by rename-detect
#                                   --persist-history at session close), so a
#                                   move that left the detector's 24h git
#                                   window is STILL repairable; merged with
#                                   any stdin records, deduped
#   --help
#
# Env:
#   RENAME_CASCADE_SCOPES  colon-separated scan roots (default: VAULT+PLANS)
#   FINDINGS_OUTPUT        redirect finding emission
#   LIBRARIAN_STDIN_WAIT   whole seconds to wait for the FIRST stdin byte before
#                          treating the (unconditional) capture as empty
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

APPLY="false"
INCLUDE_FM="false"
FROM_HISTORY="false"
SCOPES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --dry-run) shift ;;  # default; kept for CLI symmetry
    --include-frontmatter) INCLUDE_FM="true"; shift ;;
    --from-history) FROM_HISTORY="true"; shift ;;
    --scope) SCOPES="${SCOPES}${SCOPES:+:}$2"; shift 2 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
      exit 0
      ;;
    *) echo "rename-cascade: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Surface roster (SSOT): scope roots + retired denylist. A pre-set
# SURFACE_ROSTER_FILE wins (test isolation).
if [ -z "${SURFACE_ROSTER_FILE:-}" ]; then
  _SR_LIB="${SURFACE_ROSTER_LIB:-$CLAUDE_HOME_RES/hooks/lib/surface-roster.sh}"
  [ -r "$_SR_LIB" ] || _SR_LIB="$_REPO_LIB/surface-roster.sh"
  if [ -r "$_SR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$_SR_LIB"
    if command -v surface_roster_json >/dev/null 2>&1; then
      SURFACE_ROSTER_FILE="$(mktemp -t rc-roster.XXXXXX)"
      # cleanup rides the STDIN_CAPTURE/RC_WALK_LIST traps below (a trap set
      # here would be clobbered by those later assignments)
      surface_roster_json > "$SURFACE_ROSTER_FILE" 2>/dev/null || true
    fi
  fi
fi
export SURFACE_ROSTER_FILE

if [[ -z "$SCOPES" ]]; then
  # Default scope set = the roster's live roots (vault-root + memory/rules/
  # spoke corpora; vault MOUNTS ride the vault_view_walk descent of the vault
  # root, so they are not separate scopes) + the plans tree + $WORK_HOME (both
  # SSOT-resolved by paths.sh — a ~/work file's inbound [[ref]] is cascaded on
  # a rename even for a work spoke NOT symlinked into the vault). Falls back to
  # the pre-roster triple when the roster is unavailable.
  _RC_ROSTER=""
  if [ -n "${SURFACE_ROSTER_FILE:-}" ] && [ -s "$SURFACE_ROSTER_FILE" ] && command -v jq >/dev/null 2>&1; then
    _RC_ROSTER="$(jq -r '[.live[] | select(.exists and .class != "vault-mount") | .path] | join(":")' "$SURFACE_ROSTER_FILE" 2>/dev/null)"
  fi
  if [ -n "$_RC_ROSTER" ]; then
    SCOPES="${RENAME_CASCADE_SCOPES:-$_RC_ROSTER:$PLANS_DIR:${WORK_HOME:-}}"
  else
    SCOPES="${RENAME_CASCADE_SCOPES:-$VAULT_ROOT:$PLANS_DIR:${WORK_HOME:-}}"
  fi
fi

# Capture stdin to a tmp file so the python heredoc doesn't cannibalize
# the pipe (the heredoc IS the script source). Empty stdin is
# a valid no-op.
#
# THE CAPTURE IS BOUNDED ON THE FIRST BYTE. This drain is UNCONDITIONAL — every
# invocation reads fd 0, including a bare run nobody piped anything to — and fd 0
# is inherited. Under a detached / backgrounded parent it can be a live unix socket
# (or a fifo whose writer stays open) that never delivers EOF, and a bare `cat`
# there sleeps forever; the sibling handoff-disposition-check leaf hung a close-out
# gate for 12h18m on exactly that descriptor. Only the wait for the FIRST byte is
# bounded: once one byte proves the stream live the drain runs unbounded, so a slow
# upstream producer (rename-detect walking two repos before it prints) can never be
# truncated. The observed pathology delivers ZERO bytes, which is precisely what a
# first-byte bound catches. LIBRARIAN_STDIN_WAIT overrides it (whole seconds); a
# non-numeric or zero value falls back to the default rather than reaching
# `read -t 0`, which on bash 3.2 arms no timer and blocks forever.
STDIN_CAPTURE=$(mktemp -t rename-cascade-stdin.XXXXXX)
trap 'rm -f "$STDIN_CAPTURE" "${SURFACE_ROSTER_FILE:-}"' EXIT
STDIN_WAIT="${LIBRARIAN_STDIN_WAIT:-10}"
case "$STDIN_WAIT" in ''|0|*[!0-9]*) STDIN_WAIT=10 ;; esac
: > "$STDIN_CAPTURE"
RC_STDIN_FIRST=""
if IFS= read -r -t "$STDIN_WAIT" RC_STDIN_FIRST; then
  printf '%s\n' "$RC_STDIN_FIRST" > "$STDIN_CAPTURE"
  cat >> "$STDIN_CAPTURE"
elif [[ -n "$RC_STDIN_FIRST" ]]; then
  # EOF reached on an unterminated final line — keep what actually arrived.
  printf '%s' "$RC_STDIN_FIRST" > "$STDIN_CAPTURE"
fi

# Source the shared vault-view walker + materialize the
# combined per-scope file list so the scan DESCENDS the vault Skills/ symlink
# (-> ~/.claude/skills) — inbound SKILL.md/capability refs are cascaded on a rename
# (os.walk followlinks=False refused the Skills symlink). The python block reads
# RC_WALK_LIST and FALLS BACK to os.walk (walk_md) when it is empty (floor).
RC_WALK_LIST=""
_VVW_LIB="${VAULT_VIEW_WALK:-$CLAUDE_HOME_RES/hooks/lib/vault-view-walk.sh}"
[ -r "$_VVW_LIB" ] || _VVW_LIB="$_REPO_LIB/vault-view-walk.sh"
if [ -r "$_VVW_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_VVW_LIB"
  if command -v vault_view_walk >/dev/null 2>&1; then
    RC_WALK_LIST="$(mktemp -t rc-walk.XXXXXX)"
    trap 'rm -f "$STDIN_CAPTURE" "${RC_WALK_LIST:-}" "${SURFACE_ROSTER_FILE:-}"' EXIT
    _rc_oifs="$IFS"; IFS=':'
    for _rc_scope in $SCOPES; do
      IFS="$_rc_oifs"
      if [ -n "$_rc_scope" ] && [ -d "$_rc_scope" ]; then
        vault_view_walk "$_rc_scope" >> "$RC_WALK_LIST" 2>/dev/null || true
      fi
      IFS=':'
    done
    IFS="$_rc_oifs"
  fi
fi
export RC_WALK_LIST

# --from-history reads the librarian-manifest rename_history[] (same resolver
# default as hooks/lib/manifest.sh; MANIFEST_PATH env overrides).
RC_HISTORY_PATH=""
if [[ "$FROM_HISTORY" == "true" ]]; then
  RC_HISTORY_PATH="${MANIFEST_PATH:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/manifests/librarian-manifest.json}"
fi

python3 - "$APPLY" "$INCLUDE_FM" "$SCOPES" "$PLANS_DIR" "$STDIN_CAPTURE" "$RC_HISTORY_PATH" <<'PY'
import json, os, re, sys
from urllib.parse import unquote, quote

apply_s, include_fm_s, scopes_csv, plans_dir, stdin_path, history_path = sys.argv[1:7]
apply = (apply_s == "true")
include_fm = (include_fm_s == "true")
scopes = [s for s in scopes_csv.split(":") if s]

findings_out = os.environ.get("FINDINGS_OUTPUT", "")

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# ---- read NDJSON from captured stdin file ----
renames = []
try:
    stdin_lines = open(stdin_path, "r").readlines()
except Exception:
    stdin_lines = []
for ln in stdin_lines:
    ln = ln.strip()
    if not ln:
        continue
    try:
        obj = json.loads(ln)
    except Exception:
        emit({"finding": "rename-cascade-warning",
              "note": "unparseable stdin line: %s" % ln[:80]})
        continue
    if not isinstance(obj, dict):
        continue
    op = obj.get("old_path"); np = obj.get("new_path")
    if not op or not np:
        continue
    renames.append({
        "old_path": op,
        "new_path": np,
        "root": obj.get("root", ""),
        "commit": obj.get("commit_sha", ""),
        "at": obj.get("committed_at", ""),
    })

# ---- merge rename_history[] rows (--from-history) ----
# The librarian-manifest trail (populated by rename-detect --persist-history)
# outlives the detector's 24h git window: a move persisted once is repairable
# here at any later time. Rows are {from, to, at, commit, root, ...}; deduped
# against stdin records on (commit, from, to).
if history_path:
    seen_keys = set((r["commit"], r["old_path"], r["new_path"]) for r in renames)
    try:
        hist = json.load(open(history_path)).get("rename_history", [])
    except Exception:
        hist = []
    hist_rows = 0
    for row in hist if isinstance(hist, list) else []:
        if not isinstance(row, dict):
            continue
        frm, to = row.get("from", ""), row.get("to", "")
        if not frm or not to:
            continue
        key = (row.get("commit", ""), frm, to)
        if key in seen_keys:
            continue
        seen_keys.add(key)
        renames.append({
            "old_path": frm,
            "new_path": to,
            "root": row.get("root", ""),
            "commit": row.get("commit", ""),
            "at": row.get("at", ""),
        })
        hist_rows += 1
    emit({"finding": "rename-cascade-history-loaded",
          "rows": hist_rows, "store": history_path})

if not renames:
    emit({"finding": "rename-cascade-noop", "note": "stdin empty; nothing to cascade"})
    sys.exit(0)

# ---- helpers ----
EXEMPT_DIRS = (
    "/Archive/", "/.git/", "/.claude/projects/",
    "/Logs/foundations-essays/", "/Logs/backlog-progress/",
    "/_test",
)

def walk_md(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        if any(ex in dirpath + "/" for ex in EXEMPT_DIRS):
            continue
        for fn in filenames:
            # .json registries/schemas are cascade targets too
            # (the JSON path-ref pass rewrites a quoted path value on a rename).
            if fn.endswith(".md") or fn.endswith(".json"):
                yield os.path.join(dirpath, fn)

def basename_no_ext(p):
    b = os.path.basename(p)
    if b.endswith(".md"):
        b = b[:-3]
    return b

def plan_slug(p):
    # e.g. "67-vault-integrity-hardening/..." -> "vault-integrity-hardening"
    if "/" not in p:
        return ""
    top = p.split("/", 1)[0]
    m = re.match(r"^\d+-(.+)$", top)
    return m.group(1) if m else ""

# ---- build index of source files (one pass) ----
# Enumerate via the shared vault-view walker (combined
# per-scope file list at $RC_WALK_LIST) so the vault Skills/ symlink is DESCENDED and
# inbound SKILL.md/capability refs are cascaded. The walker skips dotdirs; EXEMPT_DIRS
# pruned here. FALL BACK to os.walk (walk_md) when the list is empty (floor).
sources = []
walk_list_path = os.environ.get("RC_WALK_LIST", "")
_walk_lines = []
if walk_list_path and os.path.isfile(walk_list_path):
    try:
        with open(walk_list_path) as _wf:
            _walk_lines = _wf.read().split("\n")
    except Exception:
        _walk_lines = []

# Retired denylist from the surface roster: a source routing into a retired
# surface (still on disk, never live) is never rewritten and never counted.
_ROSTER_RETIRED = []
_sr_file = os.environ.get("SURFACE_ROSTER_FILE", "")
if _sr_file and os.path.isfile(_sr_file):
    try:
        with open(_sr_file) as _sf:
            _ROSTER_RETIRED = [os.path.realpath(r.get("path")) for r in json.load(_sf).get("retired", []) if r.get("path")]
    except Exception:
        _ROSTER_RETIRED = []

def _is_retired(path_s):
    rp = os.path.realpath(path_s)
    for r in _ROSTER_RETIRED:
        if rp == r or rp.startswith(r + "/"):
            return True
    return False

for full in _walk_lines:
    # accept .json alongside .md (the walker emits every regular
    # file; the .md-only gate here previously dropped .json registries/schemas).
    if not full or not (full.endswith(".md") or full.endswith(".json")):
        continue
    if any(ex in full + "/" for ex in EXEMPT_DIRS):
        continue
    if _ROSTER_RETIRED and _is_retired(full):
        continue
    sources.append(full)
if not sources:
    for s in scopes:
        if not os.path.isdir(s) or (_ROSTER_RETIRED and _is_retired(s)):
            continue
        for f in walk_md(s):
            if _ROSTER_RETIRED and _is_retired(f):
                continue
            sources.append(f)

# ---- per-rename cascade ----
proposed = 0
applied = 0
no_op = 0
md_detected = 0

# Precompute per-rename patterns to avoid re-compiling N*M times.
rename_ops = []
for r in renames:
    old_base = basename_no_ext(r["old_path"])
    new_base = basename_no_ext(r["new_path"])
    # Wikilink pattern: [[OldBase]], [[OldBase|alias]], [[OldBase#heading]],
    # [[OldBase.md]], [[path/to/OldBase]]. We match target == old_base
    # (case-sensitive, like Obsidian's default).
    # Pattern: \[\[([^\]|#]+)(#[^\]|]+)?(\|[^\]]+)?\]\]
    # We'll iterate groups and rewrite in callback.
    # Physical old-path forms for markdown-grammar detection:
    # an md-link target resolves to a physical path, so a match against the
    # renamed file compares candidate paths, not basenames. The old file no
    # longer exists at cascade time, so both the raw-root and realpath-root
    # joins are indexed textually.
    old_abs = set()
    root = r.get("root") or ""
    if root:
        old_abs.add(os.path.normpath(os.path.join(root, r["old_path"])))
        old_abs.add(os.path.normpath(os.path.join(os.path.realpath(root), r["old_path"])))
    rename_ops.append({
        "old_path": r["old_path"],
        "new_path": r["new_path"],
        "old_base": old_base,
        "new_base": new_base,
        "old_abs": old_abs,
        "root": r["root"],
        "commit": r["commit"],
        "at": r["at"],
    })

WL = re.compile(r"\[\[([^\]\|#]+)(#[^\]\|]+)?(\|[^\]]+)?\]\]")

# Markdown-link grammar: REWRITE pass (detection landed first; the rewrite
# closes the loop). The kernel resolves each `[text](target)` against the
# source file's PHYSICAL directory and compares against the renamed old_path;
# a hit REWRITES the target to relpath(join(root, new_path), dirname(source))
# and emits `rename-cascade-mdlink`. The arithmetic is the load-bearing part:
# rename records carry repo-root-relative paths, a markdown link is
# source-file-relative — a naive substring replace mis-repairs at any depth.
# Full `[text](target)` shape required (deliberate kernel deviation): a bare
# `](x)` in prose is not a link; a rewriter must not touch it.
MD_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")

_real_dir_cache = {}
def _real_dirname(path_s):
    d = os.path.dirname(path_s)
    r = _real_dir_cache.get(d)
    if r is None:
        r = os.path.realpath(d)
        _real_dir_cache[d] = r
    return r

def _strip_code(text):
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'~~~[\s\S]*?~~~', '', text)
    text = re.sub(r'``[^`\n]+``', '', text)
    text = re.sub(r'`[^`\n]+`', '', text)
    return text

def _code_span_ranges(ln):
    ranges, start = [], None
    for i, ch in enumerate(ln):
        if ch == "`":
            if start is None:
                start = i
            else:
                ranges.append((start, i))
                start = None
    return ranges


def rewrite_mdlinks(content, op, src_path):
    """Rewrite markdown links whose physical candidate matches the renamed
    old_path to the SOURCE-FILE-RELATIVE path of new_path. Returns
    (new_content, hits). Fence- and inline-code-span-aware (a link inside a
    code context is a quotation, not a link — never rewritten; the detection
    predecessor got this via _strip_code, which a rewriter cannot use because
    it destroys the content it must return). %-quoting and #anchor tails are
    preserved on the rewritten target."""
    hits = 0
    out = []
    in_fence = False
    for ln in content.split("\n"):
        s = ln.strip()
        if s.startswith("```") or s.startswith("~~~"):
            in_fence = not in_fence
            out.append(ln)
            continue
        if in_fence:
            out.append(ln)
            continue
        spans = _code_span_ranges(ln)

        def sub(m):
            nonlocal hits
            if any(a < m.start() < b for a, b in spans):
                return m.group(0)
            raw = m.group(1)
            t = raw.strip()
            if not t or t.startswith(("/", "~", "#", "http://", "https://", "mailto:")):
                return m.group(0)
            if " " in t or "\t" in t:
                return m.group(0)
            path_part, sep, anchor = t.partition("#")
            if not path_part:
                return m.group(0)
            dec = unquote(path_part)
            cand = os.path.normpath(os.path.join(_real_dirname(src_path), dec.rstrip("/")))
            matched = cand in op["old_abs"] or (
                not op["old_abs"] and cand.endswith("/" + op["old_path"]))
            if not matched:
                return m.group(0)
            hits += 1
            root = op.get("root") or ""
            if root:
                new_abs = os.path.normpath(
                    os.path.join(os.path.realpath(root), op["new_path"]))
            else:
                # rootless record (endswith fallback): swap the old_path tail
                # for new_path on the resolved candidate
                new_abs = cand[: -len(op["old_path"])] + op["new_path"]
            new_rel = os.path.relpath(new_abs, _real_dirname(src_path))
            new_target = quote(new_rel, safe="/") + (sep + anchor if sep else "")
            full = m.group(0)
            # the target group is the trailing "(...)"; rebuild around it
            return full[: -(len(raw) + 2)] + "(" + new_target + ")"

        out.append(MD_RE.sub(sub, ln))
    return "\n".join(out), hits

# Frontmatter path-ref keys (scoped to --include-frontmatter).
# expanded beyond the original 4-key tuple to the research_path
# + binder (_situating/hub) + decision-log/research-index + library + ADR/architecture
# path keys a plan/binder frontmatter can carry, so those refs are rewritten on a rename
# (were under-matched — only spec/handoff/ideation/tasks were reached).
FM_PATH_KEYS = ("spec_path", "handoff_path", "ideation_brief_path", "tasks_path",
                "research_path", "architecture_path", "decision_log_path",
                "handoff_chronicle_path", "research_index_path",
                "situating_path", "hub_path", "library_path")

def rewrite_wikilinks(content, op):
    """Return (new_content, hits) after replacing old_base wikilinks with new_base."""
    hits = 0
    def sub(m):
        nonlocal hits
        target = m.group(1).strip()
        anchor = m.group(2) or ""
        alias = m.group(3) or ""
        # target may be "X", "X.md", "path/to/X", "path/to/X.md"
        tb = os.path.basename(target)
        tb_noext = tb[:-3] if tb.endswith(".md") else tb
        # Match on basename only — Obsidian's link-by-basename semantics.
        # Preserve .md suffix if present in original target.
        if tb_noext != op["old_base"]:
            return m.group(0)
        hits += 1
        if tb.endswith(".md"):
            new_target = op["new_base"] + ".md"
        else:
            new_target = op["new_base"]
        # preserve path prefix if present
        if "/" in target:
            prefix = target.rsplit("/", 1)[0] + "/"
            new_target = prefix + new_target
        return "[[" + new_target + anchor + alias + "]]"
    new_content = WL.sub(sub, content)
    return new_content, hits

def rewrite_frontmatter(content, op_list, is_plans_path):
    """Return (new_content, hits). Handles FM_PATH_KEYS and parent_plan."""
    if not content.startswith("---\n"):
        return content, 0
    # Split front-matter block (naive — good enough for our controlled schema).
    try:
        end_idx = content.index("\n---\n", 4)
    except ValueError:
        return content, 0
    fm_block = content[4:end_idx]
    rest = content[end_idx + 5:]
    hits = 0
    new_lines = []
    for line in fm_block.split("\n"):
        orig = line
        updated = line
        for op in op_list:
            # path-ref keys
            for key in FM_PATH_KEYS:
                # pattern: "<key>: <old_path>"  — tolerate quotes
                prefix = key + ":"
                if updated.startswith(prefix):
                    val = updated[len(prefix):].strip()
                    val_clean = val.strip('"').strip("'")
                    if val_clean == op["old_path"]:
                        updated = prefix + " " + op["new_path"]
                        hits += 1
            # parent_plan slug — only when the rename path is under PLANS_DIR.
            if is_plans_path and updated.startswith("parent_plan:"):
                val = updated[len("parent_plan:"):].strip()
                val_clean = val.strip('"').strip("'")
                old_slug = plan_slug(op["old_path"])
                new_slug = plan_slug(op["new_path"])
                if old_slug and new_slug and val_clean == old_slug:
                    updated = "parent_plan: " + new_slug
                    hits += 1
        new_lines.append(updated)
    new_fm = "\n".join(new_lines)
    if hits == 0:
        return content, 0
    return "---\n" + new_fm + "\n---\n" + rest, hits

# Determine whether each op lives under PLANS_DIR (for parent_plan scope-guard).
def under_plans(op):
    root = op.get("root") or ""
    return root.rstrip("/") == plans_dir.rstrip("/")

# Process sources once; apply all rename ops together to avoid re-read storms.
for path in sources:
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        continue
    orig_content = content
    per_file_hits = 0

    # Wikilink pass — accumulate across all rename ops.
    if "[[" in content:
        for op in rename_ops:
            new_content, hits = rewrite_wikilinks(content, op)
            if hits:
                content = new_content
                per_file_hits += hits
                emit({
                    "finding": "rename-cascade-wikilink",
                    "file": path,
                    "old_base": op["old_base"],
                    "new_base": op["new_base"],
                    "hits": hits,
                    "commit": op["commit"],
                    "mode": "apply" if apply else "dry-run",
                })
                proposed += hits

    # Markdown-link REWRITE pass: the second grammar is repaired like the
    # first — source-relative target arithmetic, not substring replace. This
    # was the last name-coupled surface (frontmatter + JSON passes below are
    # already exact-path).
    if path.endswith(".md") and "](" in content:
        for op in rename_ops:
            new_content, md_hits = rewrite_mdlinks(content, op, path)
            if md_hits:
                content = new_content
                per_file_hits += md_hits
                md_detected += md_hits
                emit({
                    "finding": "rename-cascade-mdlink",
                    "file": path,
                    "old_path": op["old_path"],
                    "new_path": op["new_path"],
                    "hits": md_hits,
                    "commit": op["commit"],
                    "mode": "apply" if apply else "dry-run",
                })
                proposed += md_hits

    # Frontmatter pass (scope-guarded by flag).
    if include_fm and content.startswith("---\n"):
        # Determine scope: parent_plan only activates for ops under PLANS_DIR.
        plans_ops = [op for op in rename_ops if under_plans(op)]
        # the walker emits pwd -P-normalized paths, so accept
        # BOTH the raw and realpath forms of plans_dir for the parent_plan scope-guard.
        is_plans_file = (path.startswith(plans_dir.rstrip("/") + "/")
                         or path.startswith(os.path.realpath(plans_dir).rstrip("/") + "/"))
        fm_ops = rename_ops  # path-refs apply everywhere
        # parent_plan substitution is gated by both the op-side (plans rename)
        # AND the target-file-side (child of a plan directory).
        new_content, hits = rewrite_frontmatter(content, fm_ops, is_plans_file)
        if hits:
            content = new_content
            per_file_hits += hits
            emit({
                "finding": "rename-cascade-frontmatter",
                "file": path,
                "hits": hits,
                "mode": "apply" if apply else "dry-run",
            })
            proposed += hits

    # JSON path-ref pass: a .json registry/schema carrying a path ref equal to a
    # renamed old_path has that value rewritten to new_path. Precise — only a QUOTED
    # exact-match string value ("old_path") is touched (the leading + trailing quote
    # anchor it), so a longer path that merely contains old_path as a segment is left
    # alone. .json never triggers the wikilink/frontmatter passes above (no [[ / no
    # leading ---), so this is the sole cascade path for JSON.
    if path.endswith(".json"):
        for op in rename_ops:
            needle = '"' + op["old_path"] + '"'
            if needle in content:
                cnt = content.count(needle)
                content = content.replace(needle, '"' + op["new_path"] + '"')
                per_file_hits += cnt
                emit({
                    "finding": "rename-cascade-json-pathref",
                    "file": path,
                    "old_path": op["old_path"],
                    "new_path": op["new_path"],
                    "hits": cnt,
                    "commit": op["commit"],
                    "mode": "apply" if apply else "dry-run",
                })
                proposed += cnt

    if per_file_hits == 0:
        continue

    if apply and content != orig_content:
        tmp = path + ".tmp.rename-cascade"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(content)
            os.replace(tmp, path)
            applied += per_file_hits
        except Exception as ex:
            emit({"finding": "rename-cascade-error",
                  "file": path,
                  "error": str(ex)})

if proposed == 0 and md_detected == 0:
    emit({"finding": "rename-cascade-noop",
          "note": "no inbound references found for %d rename(s)" % len(renames)})

emit({"finding": "rename-cascade-summary",
      "renames_consumed": len(renames),
      "proposals": proposed,
      "applied": applied,
      "mdlink_hits": md_detected,
      "scopes_scanned": scopes,
      "sources_scanned": len(sources),
      "mode": "apply" if apply else "dry-run"})
PY

exit 0
