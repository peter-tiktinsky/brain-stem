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
#   --help
#
# Env:
#   RENAME_CASCADE_SCOPES  colon-separated scan roots (default: VAULT+PLANS)
#   FINDINGS_OUTPUT        redirect finding emission
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
SCOPES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --dry-run) shift ;;  # default; kept for CLI symmetry
    --include-frontmatter) INCLUDE_FM="true"; shift ;;
    --scope) SCOPES="${SCOPES}${SCOPES:+:}$2"; shift 2 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
      exit 0
      ;;
    *) echo "rename-cascade: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$SCOPES" ]]; then
  # +$WORK_HOME so a ~/work file's inbound [[ref]] is cascaded
  # on a rename even for a work spoke NOT symlinked into the vault (a vault-surfaced
  # spoke is already reached via the vault_view_walk Work/ symlink descent, :84-104).
  SCOPES="${RENAME_CASCADE_SCOPES:-$VAULT_ROOT:$PLANS_DIR:${WORK_HOME:-}}"
fi

# Capture stdin to a tmp file so the python heredoc doesn't cannibalize
# the pipe (see memory: feedback_python_heredoc_argv.md). Empty stdin is
# a valid no-op.
STDIN_CAPTURE=$(mktemp -t rename-cascade-stdin.XXXXXX)
trap 'rm -f "$STDIN_CAPTURE"' EXIT
cat > "$STDIN_CAPTURE"

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
    trap 'rm -f "$STDIN_CAPTURE" "${RC_WALK_LIST:-}"' EXIT
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

python3 - "$APPLY" "$INCLUDE_FM" "$SCOPES" "$PLANS_DIR" "$STDIN_CAPTURE" <<'PY'
import json, os, re, sys

apply_s, include_fm_s, scopes_csv, plans_dir, stdin_path = sys.argv[1:6]
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
for full in _walk_lines:
    # accept .json alongside .md (the walker emits every regular
    # file; the .md-only gate here previously dropped .json registries/schemas).
    if not full or not (full.endswith(".md") or full.endswith(".json")):
        continue
    if any(ex in full + "/" for ex in EXEMPT_DIRS):
        continue
    sources.append(full)
if not sources:
    for s in scopes:
        if not os.path.isdir(s):
            continue
        for f in walk_md(s):
            sources.append(f)

# ---- per-rename cascade ----
proposed = 0
applied = 0
no_op = 0

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
    rename_ops.append({
        "old_path": r["old_path"],
        "new_path": r["new_path"],
        "old_base": old_base,
        "new_base": new_base,
        "root": r["root"],
        "commit": r["commit"],
        "at": r["at"],
    })

WL = re.compile(r"\[\[([^\]\|#]+)(#[^\]\|]+)?(\|[^\]]+)?\]\]")

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

if proposed == 0:
    emit({"finding": "rename-cascade-noop",
          "note": "no inbound references found for %d rename(s)" % len(renames)})

emit({"finding": "rename-cascade-summary",
      "renames_consumed": len(renames),
      "proposals": proposed,
      "applied": applied,
      "mode": "apply" if apply else "dry-run"})
PY

exit 0
