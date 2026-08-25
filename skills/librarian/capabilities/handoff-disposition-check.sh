#!/bin/bash
# handoff-disposition-check — Block session-close when touched handoff.md
# files contain unresolved follow-up language without a disposition tag.
#
# Landed: T-5 (2026-04-21). Extracted from SKILL.md
# -723 pseudocode. Enforcement layer for rule R-25 (handoff disposition
# completeness; the R-NN id resolves in the governance JSON registry).
#
# Usage:
#   handoff-disposition-check.sh --files <file> [--files <file> ...]
#   echo "<file>" | handoff-disposition-check.sh            # stdin scope
#
# Unresolved-language regex (case-insensitive):
#   (^|[^a-z])(should|later|eventually|TODO|worth watching|flagged|follow[- ]?up)([^a-z]|$)
#
# NON-PROSE SPANS ARE MASKED BEFORE THE TRIGGER SEARCH. R-25 governs unresolved
# follow-up LANGUAGE — a human sentence deferring work. Three span classes are not
# that, and matching them produced findings no author could ever resolve, because
# there is nothing there to dispose of:
#   - fenced code blocks and inline code spans: a backticked `flagged` is naming
#     the token, not deferring work.
#   - plan-slug spans (53-archive-cleanup-followup): an identifier that happens
#     to end in a trigger word. Deliberately narrow — a leading number plus at
#     least TWO hyphen-joined segments, which every plan slug has and a genuine
#     12-later does not, so the mask errs toward still firing.
#   - lines that merely REFERENCE the dispositions section rather than needing one.
# Masking replaces the span with spaces of equal width, so line/column reporting is
# unaffected. The disposition search still runs on the ORIGINAL text, so a
# backticked FIX NOW still disposes of a hit.
#
# A FOURTH CLASS WAS ADJUDICATED AND DELIBERATELY NOT MASKED: trigger words used as
# ORDINAL or descriptive adjectives rather than temporal deferrals ("the later tasks
# narrow"; "neither is a remembered follow-up", a sentence asserting the OPPOSITE of a
# deferral). The three masked classes above are all STRUCTURAL — a fence, a backtick
# pair, an identifier shape, a heading/cross-reference — each decidable from the text's
# own syntax, and each ERRS TOWARD STILL FIRING (12-later is left firing on purpose).
# The ordinal class is SEMANTIC: "the later tasks" and "the later work is deferred"
# differ only in whether the sentence defers, so any mask for it is a part-of-speech
# guess whose wrong answer DROPS A REAL FINDING SILENTLY — the one failure mode R-25
# cannot absorb. A per-line opt-out marker fails worse: it hands the author a way to
# silence the checker on the very line it is complaining about, which is a disposition
# tag that disposes of nothing. The measured cost of the alternative is one rewording
# per instance, and the reworded prose is plainer. So: reword, do not widen.
#
# Disposition tags (same line, or within the next 2 lines — SCOPED PER-ITEM: the
# lookahead is TRUNCATED at the first subsequent line that is itself a hit-line or
# starts a new bullet/list item, so a disposition belonging to the NEXT item can
# no longer satisfy this hit):
#   FIX NOW | ABSORB | STANDALONE | deferred-to:<slug>
#
# Emits blocking finding 'handoff-disposition-missing' per unresolved hit.
#
# THE STDIN FALLBACK IS BOUNDED, NEVER AN INDEFINITE READ. fd 0 is INHERITED, and
# when no --files is supplied this capability falls back to reading its scope from
# it. Under a detached / backgrounded parent that descriptor can be a live unix
# socket — or a fifo whose writer stays open — which is NOT a tty and NEVER
# delivers EOF: the `! -t 0` guard passes, no byte ever arrives, and an unbounded
# `read` sleeps forever. Not hypothetical: a close-out run whose caller passed no
# --files sat on exactly that descriptor for 12h18m with zero bytes on its captured
# stdout. Every read is bounded (see LIBRARIAN_STDIN_WAIT below), so absent input
# degrades to the empty scope this capability already documents as valid, instead
# of hanging the caller.
#
# Env overrides: FINDINGS_OUTPUT, LIBRARIAN_STDIN_WAIT.
# Bash 3.2 clean per R-23.

set -u
set -o pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"

FILES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --files) FILES="${FILES}${2}"$'\n'; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "handoff-disposition-check: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Stdin fallback if no --files provided — BOUNDED (see the header note).
# The bound is PER-READ, so a producer that keeps delivering is never truncated;
# only silence is. A non-numeric or zero override falls back to the default rather
# than reaching `read -t 0`, which on bash 3.2 arms no timer and blocks forever —
# the exact shape this bound exists to remove.
STDIN_WAIT="${LIBRARIAN_STDIN_WAIT:-5}"
case "$STDIN_WAIT" in ''|0|*[!0-9]*) STDIN_WAIT=5 ;; esac
if [[ -z "$FILES" ]] && [[ ! -t 0 ]]; then
  while IFS= read -r -t "$STDIN_WAIT" line; do
    [[ -n "$line" ]] || continue
    FILES="${FILES}${line}"$'\n'
  done
fi

if [[ -z "$FILES" ]]; then
  echo "## Handoff Dispositions (0 missing)"
  echo ""
  echo "- No handoff.md files in scope."
  exit 0
fi

MISSING=0
REPORT_LINES=""

# For each file, scan line by line.
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  # Only process *handoff.md
  case "$(basename "$file")" in
    *handoff.md) ;;
    *) continue ;;
  esac
  if [[ ! -f "$file" ]]; then
    continue
  fi

  # Use Python for precise regex + 2-line-window scan (bash 3.2 grep variants
  # can't cleanly do word-boundary + case-insensitive + N-lookahead).
  RESULT=$(python3 - "$file" <<'PY'
import re, sys
path = sys.argv[1]
# Word-boundary-guarded unresolved-language regex per SKILL.md-688.
hit_re = re.compile(
    r"(^|[^a-zA-Z])(should|later|eventually|TODO|worth watching|flagged|follow[- ]?up)([^a-zA-Z]|$)",
    re.IGNORECASE,
)
disp_re = re.compile(
    r"\b(FIX NOW|ABSORB|STANDALONE|deferred[- ]to:)",
    re.IGNORECASE,
)
# A new bullet / ordered-list item starts a new logical item — the per-item
# disposition-window boundary.
item_re = re.compile(r"^\s*([-*+]|\d+[.)])\s")

# --- non-prose span masking (the false-positive class) ---------------------
# R-25 is about unresolved follow-up LANGUAGE. These three span classes are not
# language deferring work, and a finding against them is unresolvable by
# construction: there is nothing in the span to dispose of, so the author's only
# escape was to reword an identifier or delete a code sample.
# The backtick is BUILT, never spelled, in this whole block. The python runs inside a
# $( ) command substitution, so bash tokenizes through it: an ODD number of literal
# backticks sends bash hunting for a match and it dies at the heredoc's end with a
# syntax error nowhere near the real line. Building the character removes the hazard
# instead of relying on whoever edits next to keep the count even.
_BT = chr(96)
INLINE_CODE_RE = re.compile("%s{2}[^%s\\n]+%s{2}|%s[^%s\\n]+%s" % (_BT, _BT, _BT, _BT, _BT, _BT))
# A plan slug: a leading number plus AT LEAST TWO hyphen-joined segments. Narrow on
# purpose: 53-archive-cleanup-followup is a slug, 12-later is not, and the
# ambiguous shape must keep firing rather than be silently swallowed.
PLAN_SLUG_RE = re.compile(r"\b\d{1,4}(?:-[a-z0-9]+){2,}\b", re.IGNORECASE)
# A line that POINTS AT the dispositions section instead of needing a disposition.
DISPOSITION_XREF_RE = re.compile(
    r"^\s{0,3}#{1,6}\s+.*\bdispositions?\b"
    r"|\bdispositions?\s+(?:section|table|block|list|heading|column)\b"
    r"|\b(?:see|per|under|in|below|above)\b[^.]{0,40}\bdispositions?\b"
    r"|§\s*dispositions?\b",
    re.IGNORECASE,
)
FENCE_RE = re.compile("^\\s{0,3}(%s{3}|~~~)" % _BT)

def blank(text):
    # Preserve width (and newlines) so line/column reporting is unaffected.
    return "".join("\n" if ch == "\n" else " " for ch in text)

def mask_line(text):
    text = INLINE_CODE_RE.sub(lambda mm: blank(mm.group(0)), text)
    text = PLAN_SLUG_RE.sub(lambda mm: blank(mm.group(0)), text)
    return text

try:
    with open(path) as f:
        lines = f.readlines()
except Exception:
    sys.exit(0)

masked = []
in_fence = False
for raw in lines:
    if FENCE_RE.match(raw):
        in_fence = not in_fence
        masked.append(blank(raw))
        continue
    if in_fence or DISPOSITION_XREF_RE.search(raw):
        masked.append(blank(raw))
        continue
    masked.append(mask_line(raw))

for i, line in enumerate(lines):
    # Trigger search runs on the MASKED text; everything below (the disposition
    # window, the emitted excerpt) still uses the ORIGINAL, so a backticked
    # FIX NOW still disposes of a hit and the report still quotes real prose.
    m = hit_re.search(masked[i])
    if not m:
        continue
    # Per-item disposition window: the hit's OWN line plus up to 2 lookahead
    # lines, TRUNCATED at the first subsequent line that is itself a
    # hit-line or starts a new bullet/list item — a disposition beyond that
    # boundary belongs to the NEXT item and must not satisfy this hit. R-25's
    # "same line or within the next 2 lines" contract holds for the single-item
    # case; only the cross-item bleed is closed.
    window_lines = [line]
    for j in range(i + 1, min(i + 3, len(lines))):
        nxt = lines[j]
        # Truncate on the MASKED next line: a trigger word that only appears
        # inside a slug or a code span is not a next ITEM, so it must not cut
        # this item's disposition window short.
        if hit_re.search(masked[j]) or item_re.match(nxt):
            break
        window_lines.append(nxt)
    window = "".join(window_lines)
    if disp_re.search(window):
        continue
    # Emit one record per missing-disposition hit.
    phrase = m.group(2).strip()
    trimmed = line.strip().replace('"', '\\"')
    print(f"{i+1}\t{phrase}\t{trimmed}")
PY
)

  if [[ -z "$RESULT" ]]; then
    continue
  fi

  while IFS=$'\t' read -r lineno phrase matched; do
    [[ -z "$lineno" ]] && continue
    MISSING=$((MISSING + 1))
    emit_finding "handoff-disposition-missing" "$file" \
      "line" "$lineno" \
      "phrase" "$phrase" \
      "matched" "$matched" \
      "level" "error"
    REPORT_LINES="${REPORT_LINES}- ${file}:${lineno} — \"${phrase}\" needs one of FIX NOW / ABSORB / STANDALONE / deferred-to:"$'\n'
  done <<< "$RESULT"
done <<< "$FILES"

printf "## Handoff Dispositions (%d missing)\n\n" "$MISSING"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- All unresolved language disposed."
fi

# Non-zero exit if missing — session-close contract blocks on this.
if [[ "$MISSING" -gt 0 ]]; then
  exit 1
fi
exit 0
