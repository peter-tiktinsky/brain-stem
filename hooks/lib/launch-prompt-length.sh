#!/bin/bash
# hooks/lib/launch-prompt-length.sh — launch-prompt length counter for plan handoffs.
#
# A handoff's launch prompt is the fenced block a closing session writes for the next
# session to paste verbatim. It carries only what a fresh session cannot derive from
# disk, so its length is the signal: a block well past a few hundred words restates
# files the next session loads anyway. This lib is the ONE counter both handoff checks
# share — the write-time advisory in hooks/pre-write-guard.sh and the close-time
# finding in skills/librarian/capabilities/handoff-disposition-check.sh.
#
# Sourceable; defines functions only and sets no shell options. Bash 3.2 clean
# (R-23); the python core takes its data via argv, never a piped stdin.
#
# BLOCK GRAMMAR:
#   A launch-prompt block is a ```-fenced block that directly follows (blank lines
#   allowed between) a heading matching
#     ^###[[:space:]]+Session[[:space:]]+[^[:space:]]+[[:space:]]+launch prompt
#   case-insensitive; trailing text such as "(copy verbatim)" is allowed. Its word
#   count is the whitespace-delimited tokens between the fence lines (== wc -w). An
#   unclosed fence runs to end of file. A heading or fence inside another fenced
#   block is text, not structure.
#
# NEWEST SESSION ENTRY:
#   The span from the topmost H2 that matches the handoff contract's session-heading
#   grammar (governance/file-type-contracts/handoff.md.json :: section_schema) down to
#   the next such H2 or end of file. LPL_SESSION_HEADING_RE is that grammar, taken
#   from the sibling hooks/lib/handoff-recognizer.sh (HANDOFF_SESSION_HEADING_ERE, the
#   same value the check in hooks/pre-write-guard.sh uses) and applied the same
#   way (grep -iE): "## Session <N>", "## Session S<N>", "## Alignment Session <N>", a
#   bare "## S<N>" and a date-prefixed "## <YYYY-MM-DD> — <title>". With that lib
#   unreadable the grammar is empty and launch_prompt_blocks_newest finds no entry.
#
# THRESHOLD:
#   LAUNCH_PROMPT_MAX_WORDS, default 300, strictly greater-than: 300 is silent, 301
#   is over. A non-numeric or zero value falls back to the default. The target a
#   prompt aims for is 200 words or fewer (LAUNCH_PROMPT_TARGET_WORDS).
#
# FUNCTIONS (each prints one "<heading>\t<words>" line per block, top to bottom):
#   launch_prompt_blocks <file>                every launch-prompt block in the file
#   launch_prompt_blocks_newest <file>         blocks inside the newest session entry
#   launch_prompt_blocks_new <pre> <post>      blocks in <post> whose text is absent
#                                              from <pre> (new or changed); a missing
#                                              <pre> means every block is new
#   launch_prompt_max_words                    prints the effective threshold
# A missing or unreadable <file> prints nothing and returns 0.

LAUNCH_PROMPT_TARGET_WORDS=200
_lpl_hr="$(dirname "${BASH_SOURCE[0]}")/handoff-recognizer.sh"
# shellcheck source=/dev/null
[[ -r "$_lpl_hr" ]] && . "$_lpl_hr"
LPL_SESSION_HEADING_RE="${HANDOFF_SESSION_HEADING_ERE:-}"

launch_prompt_max_words() {
  local m="${LAUNCH_PROMPT_MAX_WORDS:-300}"
  case "$m" in ''|0|*[!0-9]*) m=300 ;; esac
  printf '%s\n' "$m"
}

launch_prompt_blocks() {
  _lpl_scan all "$1" "" ""
}

launch_prompt_blocks_newest() {
  local heads=""
  [[ -r "$1" ]] || return 0
  [[ -n "$LPL_SESSION_HEADING_RE" ]] || return 0
  heads="$(grep -niE "$LPL_SESSION_HEADING_RE" "$1" 2>/dev/null | cut -d: -f1 | tr '\n' ',')" || heads=""
  _lpl_scan newest "$1" "$heads" ""
}

launch_prompt_blocks_new() {
  _lpl_scan new "$2" "" "$1"
}

# _lpl_scan <mode> <file> <session-heading-line-csv> <pre-file>
_lpl_scan() {
  [[ -r "$2" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" "$2" "$3" "$4" <<'PY' || true
import hashlib, os, re, sys

mode, path, heads_csv, pre_path = sys.argv[1:5]
BT = chr(96)  # the backtick, built rather than spelled
FENCE_OPEN = re.compile("^ {0,3}" + BT * 3)
FENCE_CLOSE = re.compile("^ {0,3}" + BT * 3 + BT + "*[ \t]*$")
LAUNCH = re.compile(r"^###\s+Session\s+\S+\s+launch prompt", re.I | re.A)


def read_lines(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read().split("\n")
    except Exception:
        return None


def scan(lines):
    """Return (blocks, fenced): blocks = [(heading_idx, heading, body)], fenced = set of
    line indexes that sit on or inside a fence."""
    fences, fenced = {}, set()
    i, n = 0, len(lines)
    while i < n:
        if FENCE_OPEN.match(lines[i]):
            j = i + 1
            while j < n and not FENCE_CLOSE.match(lines[j]):
                j += 1
            fences[i] = j
            fenced.update(range(i, min(j, n - 1) + 1))
            i = j + 1
        else:
            i += 1
    blocks = []
    for i, line in enumerate(lines):
        if i in fenced or not LAUNCH.match(line):
            continue
        j = i + 1
        while j < n and lines[j].strip() == "":
            j += 1
        if j in fences:
            body = "\n".join(lines[j + 1:fences[j]])
            heading = " ".join(line.replace("\t", " ").split())
            blocks.append((i, heading, body))
    return blocks, fenced


def words(body):
    return len(body.encode("utf-8").split())


lines = read_lines(path)
if lines is None:
    sys.exit(0)
blocks, fenced = scan(lines)

if mode == "newest":
    heads = sorted(int(x) - 1 for x in heads_csv.split(",") if x.strip().isdigit())
    heads = [h for h in heads if h not in fenced]
    if not heads:
        sys.exit(0)
    top = heads[0]
    end = heads[1] if len(heads) > 1 else len(lines)
    blocks = [b for b in blocks if top <= b[0] < end]
elif mode == "new":
    seen = set()
    if pre_path and os.path.isfile(pre_path):
        pre = read_lines(pre_path)
        if pre is not None:
            seen = {hashlib.sha256(b[2].encode("utf-8")).hexdigest() for b in scan(pre)[0]}
    blocks = [b for b in blocks if hashlib.sha256(b[2].encode("utf-8")).hexdigest() not in seen]

for _, heading, body in blocks:
    print("%s\t%d" % (heading, words(body)))
PY
}
