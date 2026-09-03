#!/bin/bash
# chronicle-index — Maintain the runtime episodic chronicle at librarian
# session-close (T-4). Read-mostly: a no-LLM walk of
# $MEM_DIR/episodic-chronicle.md performing three idempotent roles.
#   1. Pointer-metadata refresh — re-derive the `## Episodic` pointer line's
#      `last N sessions` count from the live chronicle row count and rewrite it
#      inside the sentinel block ONLY (MODEL-AFTER index-maintain's renderer
#      sentinel-bounded two-branch re-derive — never clobber hand-curation
#      outside the sentinels; idempotent).
#   2. 50KB rotation — when the chronicle exceeds ~50KB, move the OLDEST rows to
#      $MEM_DIR/episodic-chronicle-archive-<date>.md (split-to-archive; NOT
#      delete, NOT newest-N truncate). MODEL-AFTER plan-index's rotation:
#      total_counted==0 abort (exit 4) so a zero-walk never blanks the chronicle/
#      pointer; group-sum assertion (exit 3); atomic os.replace.
#   3. one-line-summary backfill — for the just-closed session's row whose
#      Summary is the LITERAL `— summary on review —`, harvest the now-written
#      handoff/close-out one-liner (no-LLM, MODEL-AFTER
#      handoff-disposition-check's python3 argv line-harvest — pass
#      paths via argv, never a piped stdin) and replace the
#      placeholder. Rows with NO harvestable close-out KEEP the placeholder
#      (graceful). Idempotent on re-run.
# Runs at librarian session-close (no 5s hook timeout) AFTER the handoff/close-out
# block is written (chained into session-close.sh::step2_integrity() AFTER
# handoff-disposition-check), so the backfill has a close-out to harvest.
# The ~50KB cap is a no-LLM PROXY for a ~12.5K-token single-read budget
# (documented in governance/file-type-contracts/episodic-chronicle.md.json) — NOT a
# measured threshold; the byte cap is a size proxy, not a token measurement.
# Output Contract
#   Files written: $MEM_DIR/episodic-chronicle.md (atomic os.replace; backfill
#     + rotation re-derive), $MEM_DIR/episodic-chronicle-archive-<date>.md
#     (rotation target, append), $MEM_DIR/MEMORY.md (sentinel-bounded pointer-line
#     metadata refresh only — never outside the sentinels).
#   Pre-write validation: a total_counted==0 walk ABORTS (exit 4) WITHOUT blanking
#     the chronicle or pointer; group-sum assertion (live+archive == pre-rotation).
#   Failure mode: block-and-log; never write-and-hope. Graceful no-op (exit 0)
#     when the memory dir / chronicle is absent.
# CLI:
#   chronicle-index.sh            # refresh pointer metadata + rotate + backfill
#   chronicle-index.sh --help
# Env overrides:
#   MEMORY_DIR                resolve_memory_dir override (test isolation)
#   CHRONICLE_MAX_BYTES       rotation byte cap (default 51200 = 50KB)
#   CLAUDE_SESSION_ID         the just-closed session id (backfill scope hint)
# Bash 3.2 clean per R-23. Read-mostly walk + atomic re-derives.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"
if [[ -z "${MEMORY_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "chronicle-index: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Resolve the memory dir. MEMORY_DIR env (test/CI) wins inside resolve_memory_dir.
MEM_DIR=""
if [[ -n "${MEMORY_DIR:-}" ]]; then
  MEM_DIR="$MEMORY_DIR"
elif command -v resolve_memory_dir >/dev/null 2>&1; then
  MEM_DIR="$(resolve_memory_dir 2>/dev/null || true)"
fi
# Graceful no-op: no resolvable memory dir.
[[ -z "$MEM_DIR" ]] && exit 0

CHRONICLE_FILE="$MEM_DIR/episodic-chronicle.md"
INDEX_FILE="$MEM_DIR/MEMORY.md"
ARCHIVE_DATE="$(date +%Y-%m-%d)"
ARCHIVE_FILE="$MEM_DIR/episodic-chronicle-archive-${ARCHIVE_DATE}.md"
MAX_BYTES="${CHRONICLE_MAX_BYTES:-51200}"

# Graceful no-op: no chronicle yet (nothing to maintain).
[[ -f "$CHRONICLE_FILE" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# The one no-LLM python3 pass: backfill -> rotation -> pointer-metadata count.
# All file paths passed via argv, never a piped stdin. Atomic os.replace
# for every write. total_counted==0 aborts WITHOUT blanking (the plan-index rule).
python3 - "$CHRONICLE_FILE" "$ARCHIVE_FILE" "$INDEX_FILE" "$MAX_BYTES" "${CLAUDE_SESSION_ID:-}" <<'PY'
import os, re, sys, tempfile

chronicle, archive, index_file, max_bytes, sid = sys.argv[1:6]
max_bytes = int(max_bytes)

ROW_MARK = "<!-- chronicle-row "
PLACEHOLDER = "— summary on review —"   # `— summary on review —`

def atomic_write(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".chronicle-index.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

try:
    with open(chronicle, encoding="utf-8") as fh:
        text = fh.read()
except Exception:
    sys.exit(0)

# Split header (everything before the first row marker) from the rows region.
first = text.find(ROW_MARK)
if first < 0:
    # Header-only / no rows — nothing to maintain. Never blank the file.
    sys.exit(0)
header = text[:first]
rows_region = text[first:]

# Carve the rows into discrete chunks, each beginning at a ROW_MARK. Newest-first
# on disk: rows[0] is the most-recent session, rows[-1] is the oldest.
positions = [m.start() for m in re.finditer(re.escape(ROW_MARK), rows_region)]
rows = []
for i, p in enumerate(positions):
    end = positions[i + 1] if i + 1 < len(positions) else len(rows_region)
    rows.append(rows_region[p:end])

total_counted = len(rows)
# plan-index's wipe-prevention rule: a zero-walk ABORTS without blanking the
# chronicle or the pointer. (Unreachable given the ROW_MARK guard above, but the
# borrowed invariant is the contract.)
if total_counted == 0:
    sys.stderr.write(
        "chronicle-index: walk found 0 chronicle rows; aborting to prevent chronicle/pointer wipe\n")
    sys.exit(4)

# --- Role 3: one-line-summary backfill --------------------------------------
# Scope: the most-recent row (rows[0]) is the just-closed session. Backfill its
# Summary placeholder from the just-written handoff/close-out one-liner. Rows with
# no harvestable close-out KEEP the placeholder (graceful). Idempotent: a row
# whose Summary is no longer the placeholder is left untouched.
def harvest_oneliner(row):
    # Resolve this row's handoff slot path (the `- **handoff:** <path>` line) and
    # harvest a one-line close-out summary from it (no-LLM, MODEL-AFTER
    # handoff-disposition-check's harvester). Prefer an explicit `**Summary:**` /
    # `## Summary` close-out line; else the first `**Next session:**` line; else
    # the first non-empty close-out prose line.
    hm = re.search(r"^- \*\*handoff:\*\*\s*(.+?)\s*$", row, re.MULTILINE)
    if not hm:
        return None
    hpath = hm.group(1).strip()
    if hpath == "— none —" or not hpath or not os.path.isfile(hpath):
        return None
    try:
        with open(hpath, encoding="utf-8") as fh:
            hlines = fh.readlines()
    except Exception:
        return None
    sum_re = re.compile(r"\*\*Summary:\*\*\s*(.+?)\s*$")
    head_re = re.compile(r"^#+\s*Summary\b", re.IGNORECASE)
    next_re = re.compile(r"\*\*Next session:\*\*\s*(.+?)\s*$")
    # (a) an inline **Summary:** one-liner.
    for ln in hlines:
        m = sum_re.search(ln)
        if m and m.group(1).strip() and m.group(1).strip() != PLACEHOLDER:
            return m.group(1).strip()
    # (b) a `## Summary` / `# Summary` heading followed by the first prose line.
    for i, ln in enumerate(hlines):
        if head_re.match(ln):
            for nx in hlines[i + 1:]:
                s = nx.strip()
                if s and not s.startswith("#"):
                    return s
            break
    # (c) the verbatim **Next session:** line as the fallback close-out signal.
    for ln in hlines:
        m = next_re.search(ln)
        if m and m.group(1).strip():
            return m.group(1).strip()
    return None

backfill_re = re.compile(
    r"(- \*\*Summary:\*\*\s*)" + re.escape(PLACEHOLDER), re.MULTILINE)
if rows and backfill_re.search(rows[0]):
    oneliner = harvest_oneliner(rows[0])
    if oneliner:
        # Replace ONLY the placeholder token after the Summary label; leave the
        # row otherwise byte-identical.
        rows[0] = backfill_re.sub(
            lambda m, o=oneliner: m.group(1) + o, rows[0], count=1)

# --- Role 2: 50KB rotation (split OLDEST rows to a dated archive) ---------------
# Rebuild the live body; if it exceeds the byte cap, move oldest rows (rows[-1],
# rows[-2], ...) to the archive until the live body is back under cap (always keep
# at least the newest row so the chronicle/pointer never blanks).
def assemble(header_text, row_list):
    return header_text + "".join(row_list)

archived = []
body = assemble(header, rows)
while len(body.encode("utf-8")) > max_bytes and len(rows) > 1:
    archived.insert(0, rows.pop())          # oldest row -> front of archive batch
    body = assemble(header, rows)

# group-sum assertion (the plan-index invariant): live rows + archived rows must equal
# the pre-rotation count — NO row is ever deleted (split-to-archive only).
if len(rows) + len(archived) != total_counted:
    sys.stderr.write("chronicle-index: group-count assertion failed (rotation lost a row)\n")
    sys.exit(3)

rotated = len(archived) > 0
if rotated:
    # Append the archived (oldest) rows to the dated archive, newest-first within
    # the batch (archived[] is already oldest-first; reverse to keep newest-first
    # so the archive matches the chronicle's newest-first convention). Create with
    # a header on first write; supersede-don't-delete the rows.
    arch_header = (
        "---\n"
        "name: episodic-chronicle-archive\n"
        "type: episodic\n"
        "tags: [\"#episode/session\", \"#chronicle\", \"#archive\"]\n"
        "---\n\n"
        "# Episodic Chronicle — Archive\n\n"
        "Rotated rows (split-to-archive at the 50KB cap; newest-first within "
        "each batch). No row is ever deleted.\n\n")
    arch_rows = "".join(reversed(archived))
    existing_arch = ""
    if os.path.isfile(archive):
        try:
            with open(archive, encoding="utf-8") as fh:
                existing_arch = fh.read()
        except Exception:
            existing_arch = ""
    if existing_arch:
        ai = existing_arch.find(ROW_MARK)
        if ai < 0:
            new_arch = existing_arch.rstrip("\n") + "\n\n" + arch_rows
        else:
            # Prepend the just-rotated (older-than-live but newer-than-archived)
            # batch above the existing archive rows.
            new_arch = existing_arch[:ai] + arch_rows + existing_arch[ai:]
    else:
        new_arch = arch_header + arch_rows
    atomic_write(archive, new_arch)

# Persist the live chronicle if Role-2 rotation or Role-3 backfill changed it.
new_text = assemble(header, rows)
if new_text != text:
    atomic_write(chronicle, new_text)

# --- Role 1: sentinel-bounded pointer-metadata refresh -------------------------
# Re-derive the `last N sessions` count in the MEMORY.md ## Episodic pointer line,
# rewriting ONLY inside the sentinel block (MODEL-AFTER index-maintain.sh sentinel
# re-derive — never clobber hand-curation outside the sentinels). Idempotent.
PTR_START = "<!-- episodic-chronicle-pointer:start -->"
PTR_END = "<!-- episodic-chronicle-pointer:end -->"
# Locate each sentinel as a WHOLE LINE — MULTILINE, anchored at line start, with
# optional trailing whitespace/CR:
#   ^<!-- episodic-chronicle-pointer:start -->[ \t\r]*$
# This is the SAME predicate the SessionEnd producer uses to decide what a live
# sentinel is, so the two surfaces can never disagree. A substring search (str.find)
# also matches an INDENTED copy inside an HTML comment, and the `last N sessions`
# rewrite below would then edit documentation text instead of a live pointer.
# Leading whitespace is deliberately NOT tolerated for exactly that reason.
PTR_START_RE = re.compile(r"^" + re.escape(PTR_START) + r"[ \t\r]*$", re.M)
PTR_END_RE = re.compile(r"^" + re.escape(PTR_END) + r"[ \t\r]*$", re.M)
if os.path.isfile(index_file):
    try:
        with open(index_file, encoding="utf-8") as fh:
            itext = fh.read()
    except Exception:
        sys.exit(0)
    m_s = PTR_START_RE.search(itext)
    m_e = PTR_END_RE.search(itext)
    s = m_s.end() if m_s else -1
    e = m_e.start() if m_e else -1
    if s >= 0 and e > s:
        block = itext[s:e]
        live_n = len(rows)            # post-rotation live row count
        # Replace the `last N sessions` count token (the producer writes the
        # literal `last N sessions`; subsequent refreshes carry a number). Never
        # touch anything outside the sentinel block.
        new_block, nsub = re.subn(
            r"(last\s+)(N|\d+)(\s+sessions)",
            lambda m: m.group(1) + str(live_n) + m.group(3),
            block, count=1)
        if nsub and new_block != block:
            new_itext = itext[:s] + new_block + itext[e:]
            atomic_write(index_file, new_itext)

sys.exit(0)
PY
rc=$?
exit "$rc"
