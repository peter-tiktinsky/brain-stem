#!/bin/bash
# context-budget-index — measure the ALWAYS-ON file surfaces and render a
# GREEN/YELLOW/RED read-replica of the context budget.
#
# WHY THIS EXISTS: CLAUDE.md, the rules/ corpus and MEMORY.md are re-sent with
# every request of every session and are re-created for every subagent, so a
# byte added there is paid on every turn — yet nothing measured them. The
# platform already emits the measurement: the InstructionsLoaded event fires
# once per instruction file loaded, carrying file_path, memory_type and
# load_reason. hooks/instructions-loaded-log.sh now RETAINS that payload (plus
# the loaded file's size) as NDJSON, and the SessionEnd seam in
# hooks/session-deregister.sh appends a per-session count of hook
# additionalContext spill files to the same log. This capability is the reader.
#
# DETECTION ONLY. Its only writes are the finding stream (hooks/lib/findings.sh:
# FINDINGS_OUTPUT or stdout) and its own read-replica pair under
# $CLAUDE_STATE_ROOT/census/. It never writes to any measured file, and it never
# blocks anything: advisory posture, exit 0 on every path.
#
# THE UNIT (governance/mandatory-files-rules.json :: mandates.
# _always_on_context_budget). CLAUDE.md and rules/ have no platform cap, so the
# thresholds are a declared convention anchored on the one always-on number the
# platform does rule on — the auto-memory byte cap. `unit_bytes` is READ from
# mandates._memory_md_cap.thresholds.max_bytes at render time, so there is only
# ever one byte literal in the system. The in-script fallbacks below exist for
# the moment the bundle is unreachable and are held in lockstep with the pillar
# by a maintainer-tree parity fixture that reads BOTH sides at test time.
#
# ROWS
#   rules-aggregate        every rule that LOADS for this cwd, summed, vs 1 unit,
#                          rendered with a contributor list (bytes, cumulative %).
#                          A user-scope paths: glob is ignored by the harness, so
#                          every user-scope rule counts; a project-scope rule
#                          counts only when it declares no paths: key.
#   rule (per file)        INFORMATIONAL. The rules tier is capped in AGGREGATE
#                          only — a per-file byte threshold would be a second
#                          invented number, which the governance slot forbids.
#   claude-md (per file)   bytes vs 1 unit AND lines vs the ~200-line convention.
#   claude-md-chain        the concatenated hierarchy, bytes vs 1 unit.
#   memory-md              NOT re-measured: the verdict is READ from the existing
#                          R-59 after-session monitor's latest `Budget status:`
#                          row in $CLAUDE_LOG_DIR/.consolidation-log.md. Absent
#                          monitor -> UNKNOWN, and the total row says PARTIAL.
#   total-always-on-files  rules aggregate + CLAUDE.md chain + MEMORY.md vs 3 units.
#   hook-spills            any spill file in the session -> RED. The spill
#                          filename carries an invocation uuid, not a hook name,
#                          so the row names the SESSION, never a guessed hook.
#   memory-template-residue  see below.
#
# THE TEMPLATE-RESIDUE ROW, and why it is a PARSER and never a fingerprint.
# The harness strips block-level HTML comments with a CommonMark type-2
# HTML-block lexer. A block opens on a line indented at most 3 spaces starting
# `<!--` and CLOSES AT THE FIRST `-->` — nesting is not understood — so
# everything after an inner `-->` up to the intended close leaks into context as
# ordinary markdown, including the stray closing `-->`. This row reproduces that
# lexer and compares its output against a nesting-AWARE strip of the same file;
# the difference is the residue the harness would load. A byte fingerprint on
# the header cannot work: an affected header's opening lines are byte-identical
# before and after the fix, so a fingerprint fires on fixed files too and gives
# zero signal. YELLOW at or above the declared residue floor; the row carries
# the residue bytes and the resolution path.
#
# Usage:
#   context-budget-index.sh              # measure, render, emit findings
#   context-budget-index.sh --help
#
# Env:
#   CLAUDE_HOME               live install root (default $HOME/.claude)
#   CENSUS_STATE_DIR          read-replica home (default $CLAUDE_STATE_ROOT/census)
#   CONTEXT_BUDGET_CWD        project scope root (default $PWD)
#   CONTEXT_BUDGET_TEMPLATE   MEMORY.md header carrier to measure for residue
#                             (default: the installed templates/MEMORY.md.template
#                             and the resolved MEMORY.md; the worse one is the row)
#   FINDINGS_OUTPUT           findings.sh routing (append file; default stdout)
#   FOUNDATION_MASTER_PATH / OVERLAY_MASTER_PATH   loader seams (testing)
#
# Exit codes: 0 ALWAYS. Advisory by contract — a non-GREEN budget is a finding,
# never a failure. 2 only on an unknown flag (usage error).
#
# Bash 3.2 clean per R-23. Data reaches python via a temp file, never a piped stdin.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [ -z "${CLAUDE_STATE_ROOT:-}" ]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && . "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && . "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && . "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || . "$_REPO_LIB/findings.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "context-budget-index: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || {
  echo "context-budget-index: python3 unavailable — clean skip (nothing measured)"
  exit 0
}

# --- Threshold resolution ----------------------------------------------------
# Bundle first, through the canonical merged-view reader (never a raw bundle
# read), with --force-override because a READ is not an overlay write. The
# constants below are the unreachable-bundle fallback and are a DUPLICATE of the
# foundation's declared slot, held in lockstep by the parity fixture that reads
# both sides at test time. The duplication is irreducible: the fallback exists
# precisely for when the bundle cannot be read, so it cannot derive from it.
CB_UNIT_BYTES=25000
CB_YELLOW_PCT=75
CB_RED_PCT=90
CB_RULES_MAX_UNITS=1
CB_CLAUDE_MD_MAX_LINES=200
CB_CLAUDE_MD_LINE_YELLOW=150
CB_CLAUDE_MD_LINE_RED=180
CB_CLAUDE_MD_MAX_UNITS_FILE=1
CB_CLAUDE_MD_MAX_UNITS_CHAIN=1
CB_TOTAL_MAX_UNITS=3
CB_TEMPLATE_RESIDUE_YELLOW_BYTES=500
CB_CONFIG_SOURCE="fallback"

_OVERLAY_LOAD="$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh"
[ -r "$_OVERLAY_LOAD" ] || _OVERLAY_LOAD="$_REPO_LIB/foundation-overlay-load.sh"
CB_SLOT_JSON=""
if [ -r "$_OVERLAY_LOAD" ] && command -v jq >/dev/null 2>&1; then
  _slot=$(bash "$_OVERLAY_LOAD" --force-override \
            --query '.mandatory_files.mandates._always_on_context_budget' 2>/dev/null || true)
  _unit=$(bash "$_OVERLAY_LOAD" --force-override \
            --query '.mandatory_files.mandates._memory_md_cap.thresholds.max_bytes' 2>/dev/null || true)
  if [ -n "$_slot" ] && printf '%s' "$_slot" | jq -e 'type == "object"' >/dev/null 2>&1; then
    CB_SLOT_JSON="$_slot"
    CB_CONFIG_SOURCE="bundle"
    _v=$(printf '%s' "$_slot" | jq -r '.bands.yellow_pct // empty' 2>/dev/null); [ -n "$_v" ] && CB_YELLOW_PCT="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.bands.red_pct // empty' 2>/dev/null); [ -n "$_v" ] && CB_RED_PCT="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.rules_unscoped_aggregate.max_units // empty' 2>/dev/null); [ -n "$_v" ] && CB_RULES_MAX_UNITS="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.claude_md.max_lines // empty' 2>/dev/null); [ -n "$_v" ] && CB_CLAUDE_MD_MAX_LINES="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.claude_md.line_bands[0] // empty' 2>/dev/null); [ -n "$_v" ] && CB_CLAUDE_MD_LINE_YELLOW="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.claude_md.line_bands[1] // empty' 2>/dev/null); [ -n "$_v" ] && CB_CLAUDE_MD_LINE_RED="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.claude_md.max_units_per_file // empty' 2>/dev/null); [ -n "$_v" ] && CB_CLAUDE_MD_MAX_UNITS_FILE="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.claude_md.max_units_per_chain // empty' 2>/dev/null); [ -n "$_v" ] && CB_CLAUDE_MD_MAX_UNITS_CHAIN="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.total_always_on_files.max_units // empty' 2>/dev/null); [ -n "$_v" ] && CB_TOTAL_MAX_UNITS="$_v"
    _v=$(printf '%s' "$_slot" | jq -r '.template_residue.yellow_min_bytes // empty' 2>/dev/null); [ -n "$_v" ] && CB_TEMPLATE_RESIDUE_YELLOW_BYTES="$_v"
    unset _v
  fi
  # The UNIT is read from its own slot — the single byte literal in the system.
  case "${_unit:-}" in
    ''|*[!0-9]*) : ;;
    *) CB_UNIT_BYTES="$_unit" ;;
  esac
  unset _slot _unit
fi
if [ "$CB_CONFIG_SOURCE" != "bundle" ]; then
  printf 'context-budget-index: threshold config DEGRADED — in-script fallbacks in effect (unit %sB, bands %s/%s); the merged-view read returned no _always_on_context_budget slot\n' \
    "$CB_UNIT_BYTES" "$CB_YELLOW_PCT" "$CB_RED_PCT" >&2
fi

# --- Inputs ------------------------------------------------------------------
STATE_DIR="${CENSUS_STATE_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/census}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
OUT_MD="$STATE_DIR/context-budget-index.md"
OUT_JSON="$STATE_DIR/context-budget-index.json"

# The telemetry log the two hooks write (same resolution expression they use).
TELEMETRY_LOG="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}/instructions-loaded.ndjson"
# The R-59 after-session monitor's durable log — the MEMORY.md verdict source.
CONSOLIDATION_LOG="${CLAUDE_LOG_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/logs}/.consolidation-log.md"

SCOPE_CWD="${CONTEXT_BUDGET_CWD:-$PWD}"

# MEMORY.md header carriers to measure for template residue: the installed
# template (what a fresh adopter is seeded with) and the live index (what an
# already-seeded adopter actually loads).
MEM_DIR_RES=""
if command -v resolve_memory_dir >/dev/null 2>&1; then
  MEM_DIR_RES="$(resolve_memory_dir 2>/dev/null || true)"
fi

CFG="$(mktemp -t ctxbudget)" || exit 0
trap 'rm -f "$CFG"' EXIT INT TERM
jq -n \
  --arg claude_home "$CLAUDE_HOME_RES" \
  --arg cwd "$SCOPE_CWD" \
  --arg telemetry "$TELEMETRY_LOG" \
  --arg consolidation "$CONSOLIDATION_LOG" \
  --arg memdir "$MEM_DIR_RES" \
  --arg template_override "${CONTEXT_BUDGET_TEMPLATE:-}" \
  --arg out_md "$OUT_MD" \
  --arg out_json "$OUT_JSON" \
  --arg cfg_source "$CB_CONFIG_SOURCE" \
  --argjson unit_bytes "$CB_UNIT_BYTES" \
  --argjson yellow_pct "$CB_YELLOW_PCT" \
  --argjson red_pct "$CB_RED_PCT" \
  --argjson rules_max_units "$CB_RULES_MAX_UNITS" \
  --argjson claude_md_max_lines "$CB_CLAUDE_MD_MAX_LINES" \
  --argjson claude_md_line_yellow "$CB_CLAUDE_MD_LINE_YELLOW" \
  --argjson claude_md_line_red "$CB_CLAUDE_MD_LINE_RED" \
  --argjson claude_md_max_units_file "$CB_CLAUDE_MD_MAX_UNITS_FILE" \
  --argjson claude_md_max_units_chain "$CB_CLAUDE_MD_MAX_UNITS_CHAIN" \
  --argjson total_max_units "$CB_TOTAL_MAX_UNITS" \
  --argjson residue_yellow "$CB_TEMPLATE_RESIDUE_YELLOW_BYTES" \
  '{claude_home: $claude_home, cwd: $cwd, telemetry: $telemetry,
    consolidation: $consolidation, memdir: $memdir,
    template_override: $template_override, out_md: $out_md, out_json: $out_json,
    cfg_source: $cfg_source,
    thresholds: {unit_bytes: $unit_bytes, yellow_pct: $yellow_pct, red_pct: $red_pct,
      rules_max_units: $rules_max_units, claude_md_max_lines: $claude_md_max_lines,
      claude_md_line_yellow: $claude_md_line_yellow, claude_md_line_red: $claude_md_line_red,
      claude_md_max_units_file: $claude_md_max_units_file,
      claude_md_max_units_chain: $claude_md_max_units_chain,
      total_max_units: $total_max_units, residue_yellow_min_bytes: $residue_yellow}}' \
  > "$CFG" 2>/dev/null || exit 0

# One python pass measures every surface, writes the .md + .json read-replica
# pair, and prints ONE tab-separated line per NON-GREEN row for the bash finding
# emitter: "<surface>\t<path>\t<status>\t<detail>". Findings are emitted by
# hooks/lib/findings.sh, never hand-formatted here.
FINDING_ROWS=$(python3 - "$CFG" <<'PYEOF'
import json, os, re, sys, glob

cfg = json.load(open(sys.argv[1]))
T = cfg["thresholds"]
UNIT = int(T["unit_bytes"])
YEL = float(T["yellow_pct"])
RED = float(T["red_pct"])

# The harness normaliser, reproduced.
#
# frontmatter is removed first; then, when the text contains "<!--", the block
# lexer runs. A type-2 HTML block opens on a line indented <= 3 spaces starting
# "<!--" and its token extends through the rest of the line carrying the
# CLOSING "-->" plus every newline that follows it. Within the token, the
# comment span is removed and the residual kept only when it is not whitespace.
# Fenced code is a different token and passes through untouched.
#
# Two closing rules, one walker:
#   harness      the block closes at the FIRST "-->" (nesting not understood)
#   depth-aware  the block closes at the "-->" that returns depth to 0
# The difference between the two outputs is exactly the residue the harness
# would load out of a nested comment.
FM_RE = re.compile(r'^---\s*\n([\s\S]*?)---\s*\n?')
FENCE_RE = re.compile(r'^ {0,3}(`{3,}|~{3,})')
OPEN_RE = re.compile(r'^ {0,3}<!--')
COMMENT_RE = re.compile(r'<!--[\s\S]*?-->')


def _physical_lines(text):
    out, start = [], 0
    for i, ch in enumerate(text):
        if ch == '\n':
            out.append(text[start:i + 1])
            start = i + 1
    if start < len(text):
        out.append(text[start:])
    return out


def _depth_close(raw):
    """Index just past the '-->' that returns comment depth to 0, or None."""
    depth, pos = 0, 0
    while True:
        a = raw.find('<!--', pos)
        b = raw.find('-->', pos)
        if a == -1 and b == -1:
            return None
        if a != -1 and (b == -1 or a < b):
            depth += 1
            pos = a + 4
        else:
            depth -= 1
            pos = b + 3
            if depth <= 0:
                return pos


def normalise(text, depth_aware):
    m = FM_RE.match(text)
    if m:
        text = text[m.end():]
    if '<!--' not in text:
        return text.strip()
    lines = _physical_lines(text)
    out, i, fence = [], 0, None
    while i < len(lines):
        body = lines[i].rstrip('\n')
        if fence is not None:
            out.append(lines[i])
            if re.match(r'^ {0,3}' + re.escape(fence), body):
                fence = None
            i += 1
            continue
        fm = FENCE_RE.match(body)
        if fm:
            fence = fm.group(1)[0] * 3
            out.append(lines[i])
            i += 1
            continue
        if not OPEN_RE.match(body):
            out.append(lines[i])
            i += 1
            continue
        # A comment block opens here. Find its closing line.
        end = i
        if depth_aware:
            depth = 0
            closed = False
            while end < len(lines) and not closed:
                pos = 0
                s = lines[end]
                while True:
                    a = s.find('<!--', pos)
                    b = s.find('-->', pos)
                    if a == -1 and b == -1:
                        break
                    if a != -1 and (b == -1 or a < b):
                        depth += 1
                        pos = a + 4
                    else:
                        depth -= 1
                        pos = b + 3
                        if depth <= 0:
                            closed = True
                            break
                if closed:
                    break
                end += 1
            if end >= len(lines):
                end = len(lines) - 1
        else:
            while end < len(lines) and '-->' not in lines[end]:
                end += 1
            if end >= len(lines):
                end = len(lines) - 1
        # The token swallows every newline that follows the closing line.
        stop = end + 1
        while stop < len(lines) and lines[stop].strip() == '':
            stop += 1
        raw = ''.join(lines[i:stop])
        if depth_aware:
            a = raw.find('<!--')
            close = _depth_close(raw)
            residual = raw[:a] + (raw[close:] if close is not None else '')
        else:
            residual = COMMENT_RE.sub('', raw)
        if residual.strip():
            out.append(residual)
        i = stop
    return ''.join(out).strip()


def read_text(path):
    try:
        with open(path, 'rb') as fh:
            return fh.read().decode('utf-8', 'replace')
    except Exception:
        return None


def nbytes(s):
    return len(s.encode('utf-8'))


def band(pct):
    if pct >= RED:
        return "RED"
    if pct >= YEL:
        return "YELLOW"
    return "GREEN"


def worse(a, b):
    order = {"GREEN": 0, "INFO": 0, "UNKNOWN": 1, "YELLOW": 2, "RED": 3}
    return a if order.get(a, 0) >= order.get(b, 0) else b


def tokens(b):
    return int(round(b / 3.5))


def pct_of(n, d):
    return (100.0 * n / d) if d else 0.0


# Telemetry: load_reason per path + the latest hook-spill row.
reasons, spill_row = {}, None
tl = cfg.get("telemetry") or ""
if tl and os.path.isfile(tl):
    try:
        with open(tl, 'r') as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                ev = row.get("event")
                if ev == "instructions-loaded" and row.get("file_path"):
                    reasons[row["file_path"]] = row.get("load_reason") or ""
                elif ev == "hook-spill-count":
                    spill_row = row
    except Exception:
        pass


def load_reason(path):
    r = reasons.get(path)
    return r if r else "session_start (assumed)"


# rules/ — every file that LOADS for this cwd.
def frontmatter_block(text):
    m = FM_RE.match(text or "")
    return m.group(1) if m else ""


def has_paths_key(text):
    for ln in frontmatter_block(text).split('\n'):
        if re.match(r'^paths\s*:', ln):
            return True
    return False


def enforced_by(text):
    for ln in frontmatter_block(text).split('\n'):
        m = re.match(r'^enforced_by\s*:\s*(.*)$', ln)
        if m:
            v = m.group(1).strip().strip('"').strip("'")
            if v:
                return v
    return "none"


rules = []
user_rules_dir = os.path.join(cfg["claude_home"], "rules")
for p in sorted(glob.glob(os.path.join(user_rules_dir, "*.md"))):
    txt = read_text(p)
    if txt is None:
        continue
    # User scope: a paths: glob is IGNORED by the harness, so every file loads.
    rules.append({"path": p, "scope": "user", "bytes": nbytes(txt),
                  "enforced_by": enforced_by(txt), "load_reason": load_reason(p)})
proj_rules_dir = os.path.join(cfg["cwd"], ".claude", "rules")
for p in sorted(glob.glob(os.path.join(proj_rules_dir, "*.md"))):
    txt = read_text(p)
    if txt is None or has_paths_key(txt):
        continue
    rules.append({"path": p, "scope": "project", "bytes": nbytes(txt),
                  "enforced_by": enforced_by(txt), "load_reason": load_reason(p)})

rules_bytes = sum(r["bytes"] for r in rules)
rules_cap = int(T["rules_max_units"]) * UNIT
rules_pct = pct_of(rules_bytes, rules_cap)
rules_band = band(rules_pct)
contributors, run = [], 0
for r in sorted(rules, key=lambda x: (-x["bytes"], x["path"])):
    run += r["bytes"]
    contributors.append({"path": r["path"], "bytes": r["bytes"],
                         "cumulative_pct": round(pct_of(run, rules_bytes), 1) if rules_bytes else 0.0})

# CLAUDE.md chain.
claude_mds = []
for p in [os.path.join(cfg["claude_home"], "CLAUDE.md"),
          os.path.join(cfg["cwd"], ".claude", "CLAUDE.md")]:
    txt = read_text(p)
    if txt is None:
        continue
    b = nbytes(txt)
    lines_n = txt.count('\n') + (0 if txt.endswith('\n') or not txt else 1)
    byte_band = band(pct_of(b, int(T["claude_md_max_units_file"]) * UNIT))
    if lines_n >= int(T["claude_md_line_red"]):
        line_band = "RED"
    elif lines_n >= int(T["claude_md_line_yellow"]):
        line_band = "YELLOW"
    else:
        line_band = "GREEN"
    claude_mds.append({"path": p, "bytes": b, "lines": lines_n,
                       "pct": round(pct_of(b, int(T["claude_md_max_units_file"]) * UNIT), 1),
                       "status": worse(byte_band, line_band),
                       "load_reason": load_reason(p)})
chain_bytes = sum(c["bytes"] for c in claude_mds)
chain_lines = sum(c["lines"] for c in claude_mds)
chain_cap = int(T["claude_md_max_units_chain"]) * UNIT
chain_pct = pct_of(chain_bytes, chain_cap)
chain_band = band(chain_pct)

# MEMORY.md — REFERENCED, never re-measured (the existing R-59 monitor owns it).
mem_status, mem_bytes, mem_detail = "UNKNOWN", None, \
    "no `Budget status:` row in the R-59 after-session monitor log — MEMORY.md is not re-measured here"
cl = cfg.get("consolidation") or ""
if cl and os.path.isfile(cl):
    last = None
    try:
        with open(cl, 'r') as fh:
            for line in fh:
                m = re.search(r'Budget status:\s*(GREEN|YELLOW|RED)\s*\(raw\s+(\d+)L\s*/\s*stripped\s+(\d+)L\s*/\s*(\d+)B', line)
                if m:
                    last = m
    except Exception:
        last = None
    if last is not None:
        mem_status = last.group(1)
        mem_bytes = int(last.group(4))
        mem_detail = "read from the R-59 after-session monitor (raw %sL / %sB)" % (last.group(2), mem_bytes)

# Total always-on files.
total_cap = int(T["total_max_units"]) * UNIT
total_bytes = rules_bytes + chain_bytes + (mem_bytes or 0)
total_pct = pct_of(total_bytes, total_cap)
total_band = band(total_pct)
total_partial = mem_bytes is None

# Hook spills.
spill_count = int(spill_row.get("count") or 0) if spill_row else 0
spill_sid = (spill_row or {}).get("session_id") or "-"
spill_band = "RED" if spill_count > 0 else "GREEN"

# MEMORY.md template residue.
candidates = []
if cfg.get("template_override"):
    candidates.append(cfg["template_override"])
else:
    candidates.append(os.path.join(cfg["claude_home"], "templates", "MEMORY.md.template"))
    if cfg.get("memdir"):
        candidates.append(os.path.join(cfg["memdir"], "MEMORY.md"))
residues = []
for p in candidates:
    txt = read_text(p)
    if txt is None:
        continue
    harness = normalise(txt, False)
    aware = normalise(txt, True)
    residues.append({"path": p, "harness_bytes": nbytes(harness),
                     "nesting_aware_bytes": nbytes(aware),
                     "residue_bytes": nbytes(harness) - nbytes(aware)})
residue_row = max(residues, key=lambda r: r["residue_bytes"]) if residues else None
residue_floor = int(T["residue_yellow_min_bytes"])
if residue_row is None:
    residue_band = "UNKNOWN"
elif residue_row["residue_bytes"] >= residue_floor:
    residue_band = "YELLOW"
else:
    residue_band = "GREEN"
RESOLUTION = ("apply the template's two comment-nesting hunks plus the schema note, "
              "or the opt-in header-refresh capability once it ships")

# Render.
def row(surface, path, b, cap, status, reason, enf, extra="", tok=None):
    p = ("%.1f%%" % pct_of(b, cap)) if cap else "—"
    t = tokens(b) if tok is None else tok
    return "| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
        surface, path, b, t, p, reason, enf, status, extra)

md = []
md.append("# Context-budget index")
md.append("")
md.append("Read-replica — regenerated by the librarian `context-budget-index` capability. "
          "Never hand-edited. Detection only: nothing measured here is written to.")
md.append("")
md.append("Unit = %d B (read from the auto-memory byte cap); bands %d%% YELLOW / %d%% RED; "
          "threshold source: %s." % (UNIT, int(YEL), int(RED), cfg["cfg_source"]))
md.append("")
md.append("`~tokens` is bytes/3.5 — an estimate, not a tokenizer count. Rows marked INFO "
          "carry no threshold: the rules tier is capped in AGGREGATE only.")
md.append("")
md.append("| surface | path | bytes | ~tokens | % of cap | load_reason | enforced_by | status | note |")
md.append("|---|---|---|---|---|---|---|---|---|")
md.append(row("rules-aggregate", "%d file(s) loading for this cwd" % len(rules),
              rules_bytes, rules_cap, rules_band, "session_start", "—",
              "cap = %d unit(s)" % int(T["rules_max_units"])))
for r in sorted(rules, key=lambda x: (-x["bytes"], x["path"])):
    md.append(row("rule", r["path"], r["bytes"], 0, "INFO",
                  r["load_reason"], r["enforced_by"], "%s scope" % r["scope"]))
for c in claude_mds:
    md.append(row("claude-md", c["path"], c["bytes"],
                  int(T["claude_md_max_units_file"]) * UNIT, c["status"],
                  c["load_reason"], "—", "%d lines (cap %d)" % (c["lines"], int(T["claude_md_max_lines"]))))
md.append(row("claude-md-chain", "%d file(s) concatenated" % len(claude_mds),
              chain_bytes, chain_cap, chain_band, "session_start", "—",
              "%d lines total" % chain_lines))
md.append(row("memory-md", "R-59 monitor verdict (not re-measured)", mem_bytes or 0,
              UNIT if mem_bytes is not None else 0, mem_status, "session_start", "R-59", mem_detail))
md.append(row("total-always-on-files", "rules aggregate + CLAUDE.md chain + MEMORY.md",
              total_bytes, total_cap, total_band, "session_start", "—",
              "PARTIAL — MEMORY.md unknown, so the total under-counts" if total_partial
              else "cap = %d unit(s)" % int(T["total_max_units"])))
md.append(row("hook-spills", "session %s" % spill_sid, (spill_row or {}).get("bytes") or 0, 0,
              spill_band, "session_end", "—",
              "%d spill file(s); any spill is RED. Spilled bytes do NOT enter context — the "
              "harness replaces them with a short preview and the file path — so no token "
              "estimate is given. The filename carries an invocation uuid, not a hook name, "
              "so no per-hook attribution is available." % spill_count, tok="—"))
if residue_row is not None:
    md.append(row("memory-template-residue", residue_row["path"],
                  residue_row["residue_bytes"], 0, residue_band, "session_start", "—",
                  "harness would load %d B where a nesting-aware strip leaves %d B; floor %d B. "
                  "Resolution: %s." % (residue_row["harness_bytes"],
                                       residue_row["nesting_aware_bytes"], residue_floor,
                                       RESOLUTION)))
else:
    md.append(row("memory-template-residue", "no MEMORY.md header carrier found", 0, 0,
                  "UNKNOWN", "—", "—", "nothing to measure"))
md.append("")
md.append("## rules/ contributors (bytes, cumulative %)")
md.append("")
if contributors:
    md.append("| file | bytes | cumulative % |")
    md.append("|---|---|---|")
    for c in contributors:
        md.append("| %s | %d | %.1f%% |" % (c["path"], c["bytes"], c["cumulative_pct"]))
else:
    md.append("_No rules load for this cwd._")
md.append("")

doc = {
    "generated_by": "skills/librarian/capabilities/context-budget-index.sh",
    "cwd": cfg["cwd"],
    "threshold_source": cfg["cfg_source"],
    "thresholds": T,
    "surfaces": {
        "rules_aggregate": {"bytes": rules_bytes, "cap": rules_cap,
                            "pct": round(rules_pct, 1), "status": rules_band,
                            "files": len(rules), "contributors": contributors},
        "rules": rules,
        "claude_md": claude_mds,
        "claude_md_chain": {"bytes": chain_bytes, "lines": chain_lines, "cap": chain_cap,
                            "pct": round(chain_pct, 1), "status": chain_band},
        "memory_md": {"status": mem_status, "bytes": mem_bytes, "detail": mem_detail,
                      "re_measured": False},
        "total_always_on_files": {"bytes": total_bytes, "cap": total_cap,
                                  "pct": round(total_pct, 1), "status": total_band,
                                  "partial": total_partial},
        "hook_spills": {"count": spill_count, "session_id": spill_sid,
                        "status": spill_band, "by_hook": None,
                        "by_hook_unavailable": "spill filenames carry an invocation uuid, not the emitting hook name"},
        "memory_template_residue": {"measured": residues, "row": residue_row,
                                    "floor_bytes": residue_floor,
                                    "status": residue_band, "resolution": RESOLUTION},
    },
}

for path, payload in ((cfg["out_md"], "\n".join(md) + "\n"),
                      (cfg["out_json"], json.dumps(doc, indent=2, sort_keys=True) + "\n")):
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        tmp = path + ".tmp"
        with open(tmp, 'w') as fh:
            fh.write(payload)
        os.rename(tmp, path)
    except Exception:
        pass

# NON-GREEN rows only — INFO rows carry no threshold and never emit.
out = []
if rules_band != "GREEN":
    out.append(("rules-aggregate", user_rules_dir, rules_band,
                "%d B over %d file(s) vs a %d B cap (%.1f%%); top contributor %s"
                % (rules_bytes, len(rules), rules_cap, rules_pct,
                   contributors[0]["path"] if contributors else "-")))
for c in claude_mds:
    if c["status"] != "GREEN":
        out.append(("claude-md", c["path"], c["status"],
                    "%d B (%.1f%% of cap) / %d lines (cap %d)"
                    % (c["bytes"], c["pct"], c["lines"], int(T["claude_md_max_lines"]))))
if chain_band != "GREEN":
    out.append(("claude-md-chain", cfg["cwd"], chain_band,
                "%d B across %d file(s) vs a %d B cap (%.1f%%)"
                % (chain_bytes, len(claude_mds), chain_cap, chain_pct)))
if mem_status not in ("GREEN",):
    out.append(("memory-md", cl or "-", mem_status, mem_detail))
if total_band != "GREEN" or total_partial:
    out.append(("total-always-on-files", cfg["cwd"],
                total_band if not total_partial else worse(total_band, "UNKNOWN"),
                "%d B vs a %d B cap (%.1f%%)%s"
                % (total_bytes, total_cap, total_pct,
                   "; PARTIAL — MEMORY.md unknown" if total_partial else "")))
if spill_band != "GREEN":
    out.append(("hook-spills", spill_sid, spill_band,
                "%d hook additionalContext spill file(s) this session; no per-hook attribution is derivable from the filename"
                % spill_count))
if residue_band not in ("GREEN",):
    out.append(("memory-template-residue", (residue_row or {}).get("path", "-"), residue_band,
                "%s B of nested-comment residue the harness would load (floor %d B). Resolution: %s"
                % ((residue_row or {}).get("residue_bytes", "?"), residue_floor, RESOLUTION)))
for s, p, st, d in out:
    print("%s\t%s\t%s\t%s" % (s, p, st, d.replace("\t", " ")))
PYEOF
) || FINDING_ROWS=""

NON_GREEN=0
while IFS=$'\t' read -r f_surface f_path f_status f_detail; do
  [ -z "${f_surface:-}" ] && continue
  NON_GREEN=$((NON_GREEN + 1))
  emit_finding "context-budget" "$f_path" \
    "surface" "$f_surface" "status" "$f_status" "detail" "$f_detail"
done <<EOF
$FINDING_ROWS
EOF

echo "context-budget-index: rendered $OUT_MD (+ .json); $NON_GREEN non-GREEN row(s); thresholds from $CB_CONFIG_SOURCE; advisory — never blocks"
exit 0
