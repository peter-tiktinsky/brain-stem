#!/bin/bash
# Hook: PostToolUse (Edit|Write) — R-44 _index regen entry-point.
# C1-owned body (canonical/PostToolUse Edit|Write fire-order #2:
# track-vault-write -> post-write-verify -> memory-auto-stamp ->
# memory-globalize-auto;.4/.6 R-44 _index Tier-1 vehicle).
# DOUBLE load-bearing (gap-register):
#   1. body — the wired-but-unauthored PostToolUse Edit|Write body.
#   2. R-44 _index Tier-1 vehicle — the regen entry-point is invocable here; the
#      session-close CHAINING of it is/(out of scope).
# — write-time Tier-1 _index.md bootstrap for REGISTERED Work
# subdirs. A normal PostToolUse fire (no --index-regen flag) now bootstraps the
# folder's _index.md when a deliverable lands in a registered Work subtree. The
# property is perf-budgeted and fail-open; the gate chain (in fire order) is:
#   1. WORK_CONFIGURED gate (perf floor) — WORK_CONFIGURED=0 → exit 0, no work.
#   2. physical-prefix prefilter — the write's real parent (pwd -P) must be under
#      $WORK_HOME/ or $VAULT_ROOT/Work/; otherwise exit 0 BEFORE any jq/overlay read.
#   3. _index.md stat-first short-circuit — if the folder already has _index.md,
#      exit 0 WITHOUT an overlay read (steady state is overlay-read-free).
#   4. overlay-load (foundation-overlay-load.sh AS AN EXECUTABLE, not sourced) —
#      fired AT MOST ONCE per qualifying write, mirroring pre-write-guard's pattern.
#   5. registered-pattern gate — REL_DIR (the vault-view Work/<spoke>/… dir, same
#      remap shape as) must match a .frontmatter.path_routing.rules[].pattern;
#      an UNregistered (State-A) Work subdir matches nothing → no _index.
#   6. atomic bootstrap — _index.md written via mkstemp+os.replace, REUSING the
#      EXACT shape from index-maintain.sh (Tier-1/Tier-2 byte-parity except updated:).
# Fail-open everywhere: any missing dependency, malformed/empty UNION_JSON, or
# error leaves the folder untouched and exits 0. The prior Logs/ auto-govern
# branch was retired at G3 (vault stopped shipping Logs/).
# NEVER deny, NEVER fail-hard; exit 0 always.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR. paths.sh provides
# CLAUDE_HOME resolution for the index-maintain delegate below.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0

# --- R-44 Tier-1 _index regen entry-point (invocable; chaining =) ------
# The vault-health _index regen vehicle. The session-close chain (R-44 /)
# invokes this; here it is authored as an invocable entry-point only. Delegates
# to the librarian index-maintain capability when present (Tier-2), else no-op.
post_write_verify_index_regen() {
  local target="${1:-}"
  local cap="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/index-maintain.sh"
  if [ -x "$cap" ]; then
    "$cap" "$target" >/dev/null 2>&1 || true
  fi
  return 0
}

# Internal entry-point so the regen vehicle is directly invocable (wiring
# target): `post-write-verify.sh --index-regen [path]`.
if [ "${1:-}" = "--index-regen" ]; then
  post_write_verify_index_regen "${2:-}"
  exit 0
fi

# jq is required to read the stdin path (cohort auto-stamp + the overlay rules).
command -v jq >/dev/null 2>&1 || exit 0

# Read the PostToolUse stdin JSON ONCE — shared by the forward-governance cohort
# auto-stamp (T-7) AND the _index bootstrap below. Only tool_input.file_path is
# consumed (PostToolUse also carries tool_response — ignored). Fail-open throughout.
PWV_INPUT="$(cat)"
PWV_FILE_PATH="$(printf '%s' "$PWV_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -n "$PWV_FILE_PATH" ] || exit 0

# === T-7: forward-governance cohort auto-stamp (Mechanism 1) =================
# Auto-stamp a vault-RESIDENT, frontmatter-bearing .md file with the universal
# cohort at write-time — but ONLY the fields that are ABSENT (created + an immutable
# readable id slug are stamped once and never regenerated on a re-write; the stored
# id survives a later move/rename). Location-based scope: the file must be physically
# under $VAULT_ROOT. EXCLUDED: memory files (memory-auto-stamp.sh owns created=today
# there — a git-date backfill would collide), CLAUDE.md (navigation/context,
# frontmatter-less), _index.md (the Tier-1/Tier-2 bootstrap stamps its own cohort),
# and type: log (out-of-folder machine exhaust). Fast pre-gate: no python spawns
# unless a cohort field is actually missing (steady state = one grep). The symlinked
# Work/ surface is covered by the scaffolder (cohort-emitting) + the frontmatter-enforce
# --fix backfill, not here. Fail-open: any error leaves the file untouched.
if [ "${VAULT_CONFIGURED:-0}" = "1" ] && [ -n "${VAULT_ROOT:-}" ] \
   && [ "${PWV_FILE_PATH#$VAULT_ROOT/}" != "$PWV_FILE_PATH" ] \
   && [ "${PWV_FILE_PATH%.md}" != "$PWV_FILE_PATH" ] \
   && [ -f "$PWV_FILE_PATH" ] \
   && command -v python3 >/dev/null 2>&1; then
  _cs_base="${PWV_FILE_PATH##*/}"
  case "$PWV_FILE_PATH" in */memory/*) _cs_skip=1 ;; *) _cs_skip=0 ;; esac
  if [ "$_cs_skip" = "0" ] && [ "$_cs_base" != "CLAUDE.md" ] && [ "$_cs_base" != "_index.md" ] \
     && [ "$(head -1 "$PWV_FILE_PATH" 2>/dev/null)" = "---" ]; then
    # Fast pre-gate — only proceed if a cohort field is actually missing.
    _cs_fm="$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$PWV_FILE_PATH" 2>/dev/null)"
    _cs_need=0
    for _cs_k in created id schema_version description; do
      printf '%s\n' "$_cs_fm" | grep -qE "^${_cs_k}:" || { _cs_need=1; break; }
    done
    if [ "$_cs_need" = "1" ]; then
      _cs_rel="${PWV_FILE_PATH#$VAULT_ROOT/}"
      _cs_slug="$(printf '%s' "${_cs_rel%.md}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//')"
      [ -n "$_cs_slug" ] || _cs_slug="note"
      _cs_today="$(date +%Y-%m-%d)"
      _cs_desc=""
      printf '%s\n' "$_cs_fm" | grep -qE '^description:' \
        || _cs_desc="$(bash "$SCRIPT_DIR/lib/derive-description.sh" "$PWV_FILE_PATH" 2>/dev/null || true)"
      python3 - "$PWV_FILE_PATH" "$_cs_today" "$_cs_slug" "$_cs_desc" 2>/dev/null <<'PYCS' || true
import sys, os, re
path, today, slug, desc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(path, encoding="utf-8") as fh:
        content = fh.read()
except OSError:
    sys.exit(0)
if not content.startswith("---\n"):
    sys.exit(0)   # no frontmatter → leave to the T-8 fixer
end = content.find("\n---\n", 4)
if end < 0:
    sys.exit(0)
fm_text = content[4:end]
body = content[end + 5:]
KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')
lines = fm_text.split("\n")
keys = {}
for i, ln in enumerate(lines):
    m = KEY_RE.match(ln)
    if m:
        keys[m.group(1)] = i
if not keys:
    sys.exit(0)
# type: log is out-of-folder machine exhaust — out of cohort scope.
if "type" in keys:
    tv = (KEY_RE.match(lines[keys["type"]]).group(2) or "").strip().strip('"').strip("'")
    if tv == "log":
        sys.exit(0)
def add_if_absent(k, v):
    if k not in keys and v != "":
        lines.append("%s: %s" % (k, v))
        keys[k] = len(lines) - 1
add_if_absent("created", today)
add_if_absent("id", slug)
add_if_absent("schema_version", "1")
if desc:
    d = desc.replace('"', "'")
    if re.search(r':\s', d) or d[:1] in "#&*!|>%@`[]{},":
        d = '"%s"' % d
    add_if_absent("description", d)
new_content = "---\n" + "\n".join(lines) + "\n---\n" + body
if new_content == content:
    sys.exit(0)
tmp = path + ".cohort-stamp.tmp"
try:
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(new_content)
    os.replace(tmp, path)
except OSError:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(0)
PYCS
    fi
  fi
fi
# === end T-7 cohort auto-stamp ==============================================

# ---: normal-fire Tier-1 _index.md bootstrap for registered Work subdirs ---
# Gate 1 — WORK_CONFIGURED perf floor: no Work surface configured → no _index work.
if [ "${WORK_CONFIGURED:-0}" != "1" ]; then
  exit 0
fi

# Gate 2 — physical-prefix prefilter (BEFORE any overlay read). Resolve the real
# parent dir via `pwd -P` (matches the remap primitive; not realpath). The
# write must be physically inside $WORK_HOME/ OR $VAULT_ROOT/Work/. A bare-string
# fallback covers a first write into a not-yet-existing dir. Not under Work → exit 0.
PWV_PARENT="${PWV_FILE_PATH%/*}"
PWV_BASE="${PWV_FILE_PATH##*/}"
PWV_REAL_PARENT=""
if [ -d "$PWV_PARENT" ]; then
  PWV_REAL_PARENT="$(cd "$PWV_PARENT" 2>/dev/null && pwd -P 2>/dev/null || true)"
fi
[ -n "$PWV_REAL_PARENT" ] || PWV_REAL_PARENT="$PWV_PARENT"

PWV_REAL_WORKHOME=""
if [ -n "${WORK_HOME:-}" ] && [ -d "$WORK_HOME" ]; then
  PWV_REAL_WORKHOME="$(cd "$WORK_HOME" 2>/dev/null && pwd -P 2>/dev/null || true)"
fi
[ -n "$PWV_REAL_WORKHOME" ] || PWV_REAL_WORKHOME="${WORK_HOME:-}"
PWV_REAL_VAULTWORK=""
if [ -n "${VAULT_ROOT:-}" ] && [ -d "$VAULT_ROOT/Work" ]; then
  PWV_REAL_VAULTWORK="$(cd "$VAULT_ROOT/Work" 2>/dev/null && pwd -P 2>/dev/null || true)"
fi

# REL_DIR = the vault-view directory (Work/<spoke>/<sub>...) for the write's parent.
# Same remap shape as: a physical $WORK_HOME/<rest> dir maps to Work/<rest>;
# a $VAULT_ROOT/Work/<rest> dir maps to Work/<rest> directly.
PWV_REL_DIR=""
case "$PWV_REAL_PARENT/" in
  "$PWV_REAL_WORKHOME"/*)
    PWV_REL_DIR="Work/${PWV_REAL_PARENT#$PWV_REAL_WORKHOME/}" ;;
  *)
    if [ -n "$PWV_REAL_VAULTWORK" ]; then
      case "$PWV_REAL_PARENT/" in
        "$PWV_REAL_VAULTWORK"/*)
          PWV_REL_DIR="Work/${PWV_REAL_PARENT#$PWV_REAL_VAULTWORK/}" ;;
      esac
    fi ;;
esac
# Not physically under a Work surface → no-op (overlay read never fires).
[ -n "$PWV_REL_DIR" ] || exit 0
# Normalize a possible trailing slash from a $WORK_HOME-root write (no <rest>).
PWV_REL_DIR="${PWV_REL_DIR%/}"

# Gate 3 — _index.md stat-first short-circuit. The bootstrap target is the write's
# PHYSICAL parent dir (where the deliverable actually lands). If it already has an
# _index.md, this folder's Tier-1 is done → exit 0 WITHOUT an overlay read. This
# keeps the steady state (every subsequent write into the folder) overlay-read-free.
PWV_IDX="$PWV_REAL_PARENT/_index.md"
[ -f "$PWV_IDX" ] && exit 0

# Gate 4 — overlay-load AS AN EXECUTABLE (NOT sourced), fired AT MOST ONCE here,
# mirroring the pre-write-guard invocation pattern. Resolve the standalone CLI via
# $FOUNDATION_OVERLAY_LOAD (test isolation) else the repo/installed lib location.
PWV_FOUNDATION_MASTER="${FOUNDATION_MASTER:-${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json}"
PWV_OVL="${FOUNDATION_OVERLAY_LOAD:-}"
if [ -z "$PWV_OVL" ]; then
  if [ -x "$SCRIPT_DIR/lib/foundation-overlay-load.sh" ]; then
    PWV_OVL="$SCRIPT_DIR/lib/foundation-overlay-load.sh"
  elif [ -x "$SCRIPT_DIR/../lib/foundation-overlay-load.sh" ]; then
    PWV_OVL="$SCRIPT_DIR/../lib/foundation-overlay-load.sh"
  fi
fi
[ -n "$PWV_OVL" ] && [ -x "$PWV_OVL" ] && [ -f "$PWV_FOUNDATION_MASTER" ] || exit 0

# Materialize the union to a temp file (the python heredoc below consumes stdin,
# so the union JSON travels via a file path in argv — never piped, per the
# python-heredoc/argv rule). mkstemp via mktemp; cleaned on EXIT.
PWV_UNION_FILE="$(mktemp 2>/dev/null || true)"
[ -n "$PWV_UNION_FILE" ] || exit 0
trap 'rm -f "$PWV_UNION_FILE"' EXIT
"$PWV_OVL" \
  --foundation-path "$PWV_FOUNDATION_MASTER" \
  --overlay-path "${OVERLAY_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/overlay-master.json}" \
  --force-override > "$PWV_UNION_FILE" 2>/dev/null || true
# Fail-open: empty/malformed union → no write.
[ -s "$PWV_UNION_FILE" ] || exit 0

# Gates 5 + 6 — registered-pattern match + atomic single-folder bootstrap. REUSES
# the EXACT _index.md shape from index-maintain.sh (type:index + parent_folder at
# depth>=1 + tags + updated + # <folder> + ## Contents + contents-enum sentinels;
# atomic mkstemp+os.replace). The python body matches PWV_REL_DIR against
# .frontmatter.path_routing.rules[]?.pattern (same fnmatch semantics as
# index-maintain.sh's de-exemption walk) and writes ONLY when a pattern matches.
python3 - "$PWV_REAL_PARENT" "$PWV_REL_DIR" "$PWV_UNION_FILE" <<'PYBOOT' 2>/dev/null || true
import json, os, re, sys, tempfile, fnmatch
from datetime import date

dirpath, rel_dir, union_path = sys.argv[1], sys.argv[2], sys.argv[3]
today = date.today().isoformat()

START = "<!-- contents-enum:start -->"
END = "<!-- contents-enum:end -->"

# Load the merged union; fail-open on any parse error (no write).
try:
    with open(union_path, encoding="utf-8") as fh:
        union = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(union, dict):
    sys.exit(0)

# Gate 5 — registered-pattern match. Pull every frontmatter.path_routing.rules[].pattern
# and match rel_dir (the vault-view Work/<spoke>/<sub> dir). Same fnmatch semantics
# as index-maintain.sh's _glob_match (a `/**` glob also matches its own base dir).
rules = (((union.get("frontmatter") or {}).get("path_routing") or {}).get("rules") or [])
patterns = [r.get("pattern") for r in rules
            if isinstance(r, dict) and isinstance(r.get("pattern"), str) and r.get("pattern")]

def _expand_braces(glob):
    # Expand a {a,b} alternation into brace-free globs (fnmatch has no brace
    # support). A brace-free glob returns unchanged.
    i = glob.find("{")
    if i < 0:
        return [glob]
    j = glob.find("}", i)
    if j < 0:
        return [glob]
    pre, opts, post = glob[:i], glob[i + 1:j], glob[j + 1:]
    out = []
    for opt in opts.split(","):
        out.extend(_expand_braces(pre + opt + post))
    return out

def _glob_match(rel, glob):
    for g in _expand_braces(glob):
        if fnmatch.fnmatch(rel, g):
            return True
        if g.endswith("/**") and fnmatch.fnmatch(rel, g[:-3]):
            return True
    return False

rel = rel_dir.replace(os.sep, "/")
if not any(_glob_match(rel, g) for g in patterns):
    sys.exit(0)   # State-A (unregistered) Work subdir → no _index

# The folder must exist to host an _index.md (the parent dir of the just-written
# deliverable). A second stat-short-circuit (the shell already checked, but a
# concurrent write may have created it).
if not os.path.isdir(dirpath):
    sys.exit(0)
idx_path = os.path.join(dirpath, "_index.md")
if os.path.isfile(idx_path):
    sys.exit(0)

# Gate 6 — atomic single-folder bootstrap. Shape is BYTE-IDENTICAL to
# index-maintain.sh's auto-bootstrap branch (except the `updated:` date is today's).
def file_type(path):
    try:
        with open(path, encoding="utf-8") as fh:
            head = fh.read(2048)
    except Exception:
        return ""
    if not head.startswith("---"):
        return ""
    end = head.find("\n---", 3)
    if end == -1:
        return ""
    for line in head[3:end].splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if m and m.group(1) == "type":
            return m.group(2)
    return ""

def line_count(path):
    try:
        with open(path, "rb") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0

try:
    children = [f for f in os.listdir(dirpath)
                if f.endswith(".md") and f != "_index.md" and not f.startswith(".")
                and os.path.isfile(os.path.join(dirpath, f))]
except Exception:
    sys.exit(0)

rows = []
for c in sorted(children):
    cp = os.path.join(dirpath, c)
    rows.append("| [[%s]] | %d | %s | |" % (c[:-3], line_count(cp), file_type(cp) or "—"))
folder = os.path.basename(dirpath) or os.path.basename(os.path.dirname(dirpath))
parent = os.path.basename(os.path.dirname(dirpath)) if os.sep in rel_dir else ""
fm_lines = ["---", "type: index"]
if parent:
    fm_lines.append("parent_folder: %s" % parent)
_cohort_slug = re.sub(r"[^a-z0-9]+", "-", (rel or folder).lower()).strip("-") or "index"
fm_lines += ["description: Folder index for %s." % folder, "created: %s" % today, "tags: [\"#scope/reference\"]", "updated: %s" % today, "id: index-%s" % _cohort_slug, "schema_version: 1", "---", ""]
body = "\n".join(fm_lines)
body += "# %s\n\n_Folder index (auto-bootstrapped). Add a folder-context paragraph._\n\n" % folder
body += "## Contents\n\n" + START + "\n"
body += "| Name | Lines | Type | Description |\n|------|-------|------|-------------|\n"
body += ("\n".join(rows) + "\n") if rows else ""
body += END + "\n"
try:
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._index.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, idx_path)
except Exception:
    sys.exit(0)
PYBOOT
exit 0
