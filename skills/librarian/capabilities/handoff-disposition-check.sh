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
#   find <plans-root> -name '*handoff.md' | handoff-disposition-check.sh   # whole corpus
#
# A whole-corpus report is a triage pass, not a close gate. Point FINDINGS_OUTPUT at a
# scratch file so the finding NDJSON lands there, apart from the markdown summary on
# stdout (unset, each finding prints inline with it). The exit is non-zero whenever a
# hit is found, which on a triage pass is the expected result, not a failure.
#
# Callers: session-close.sh runs it over the touched handoffs and BLOCKS on a miss;
# hooks/pre-write-guard.sh's write-time arm (handoff block) runs it with
# --files over a temp copy of each handoff write's NEW content and returns the hits
# as an ALLOW advisory (never a deny). The trigger regex and masks live here only.
#
# Unresolved-language regex (case-insensitive; a plural "s" is part of the word, so
# "SHOULDs", "TODOs" and "follow-ups" are hits while "shoulders" and "laterals" are not):
#   (^|[^a-z])(should|later|eventually|TODO|worth watching|flagged|follow[- ]?up)s?([^a-z]|$)
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
#   FIX NOW | ABSORB | STANDALONE | NO-BUILD | deferred-to:<slug>
# ABSORB and NO-BUILD are case-sensitive: only the uppercase stem is a tag (ABSORB,
# ABSORBED, ABSORBed; NO-BUILD). Lower-case and title-case inflections ("not absorbed",
# "absorbs", "Absorbed into", "no-build") are prose and dispose of nothing. The other
# tags match any case.
#
# ABSORB and deferred-to: carry a TARGET discipline: the text following the tag
# to the end of the per-item window must name the specific target — a plan slug,
# a task id, or an NN/T-n pair. A floating target ("the next architect run",
# "a future session") is functionally a "remember this" and fails exactly like a
# missing tag. Emits blocking finding 'handoff-disposition-target-unspecific'.
# FIX NOW is target-less by contract and never triggers it.
#
# A RESOLVABLE TARGET. Inside the file's NEWEST session entry (the topmost H2 matching
# the session-heading grammar of hooks/lib/launch-prompt-length.sh, down to the next
# such H2 or end of file), a hit disposed by STANDALONE, ABSORB or NO-BUILD must name,
# in the rest of its per-item window, a token that resolves on disk under the plans
# root (PLANS_ROOT, else PLANS_DIR): _inbox/<slug>.md, _inbox/_settled/<slug>.md, or
# <key>/manifest.json (a sub-plan key <plan>/<sub> resolves too; an optional
# ":: T-N" suffix is stripped); a bare slug resolves through _inbox/<slug>.md. A hit with
# no resolving token emits blocking 'handoff-disposition-target-unresolved', counted in
# the exit contract. The unspecific test above keeps precedence for ABSORB and
# deferred-to:; FIX NOW and deferred-to: never take this one. Outside the newest entry,
# and in a file with no session heading, only the lexical check above applies.
#
# Emits blocking finding 'handoff-disposition-missing' per unresolved hit.
#
# LAUNCH-PROMPT LENGTH (warn, never blocking). For each launch-prompt block inside
# the file's NEWEST session entry whose word count exceeds LAUNCH_PROMPT_MAX_WORDS
# (default 300, strictly greater-than), emits a warn-level
# 'handoff-launch-prompt-long' finding naming the heading, the count, the threshold
# and the 200-word target. It is NOT counted in the "(N missing)" total and never
# changes the exit code. Block grammar, entry boundary and counter live in
# hooks/lib/launch-prompt-length.sh; a missing lib skips the check silently.
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
# Env overrides: FINDINGS_OUTPUT, LIBRARIAN_STDIN_WAIT, LAUNCH_PROMPT_MAX_WORDS.
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
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/launch-prompt-length.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/launch-prompt-length.sh"; } \
  || { [ -r "$_REPO_LIB/launch-prompt-length.sh" ] && source "$_REPO_LIB/launch-prompt-length.sh"; } \
  || true
LPL_AVAILABLE=0
declare -F launch_prompt_blocks_newest >/dev/null 2>&1 && LPL_AVAILABLE=1

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
LONG=0
LONG_LINES=""
LP_MAX=300
[[ "$LPL_AVAILABLE" == "1" ]] && LP_MAX="$(launch_prompt_max_words)"

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
  # Newest session entry line span (1-based, inclusive) for the resolvable-target rule;
  # "0 0" turns the rule off (no heading grammar, or no matching heading in the file).
  SPAN_LO=0; SPAN_HI=0
  if [[ -n "${LPL_SESSION_HEADING_RE:-}" ]]; then
    HEAD_LINES="$(grep -niE "$LPL_SESSION_HEADING_RE" "$file" 2>/dev/null | cut -d: -f1)" || HEAD_LINES=""
    SPAN_LO="$(printf '%s\n' "$HEAD_LINES" | sed -n '1p')"
    SPAN_NEXT="$(printf '%s\n' "$HEAD_LINES" | sed -n '2p')"
    if [[ "$SPAN_LO" =~ ^[0-9]+$ ]]; then
      if [[ "$SPAN_NEXT" =~ ^[0-9]+$ ]]; then
        SPAN_HI=$((SPAN_NEXT - 1))
      else
        SPAN_HI="$(wc -l < "$file" | tr -d ' ')"
        SPAN_HI=$((SPAN_HI + 1))
      fi
    else
      SPAN_LO=0; SPAN_HI=0
    fi
  fi
  PLANS_ROOT_RES="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"

  RESULT=$(python3 - "$file" "$SPAN_LO" "$SPAN_HI" "$PLANS_ROOT_RES" <<'PY'
import os, re, sys
path = sys.argv[1]
span_lo, span_hi = int(sys.argv[2]), int(sys.argv[3])
plans_root = sys.argv[4]
# Word-boundary-guarded unresolved-language regex per SKILL.md-688.
# The optional plural "s" sits inside the right-hand boundary, so a plural is a hit
# and a longer word on the same stem is not.
hit_re = re.compile(
    r"(^|[^a-zA-Z])(should|later|eventually|TODO|worth watching|flagged|follow[- ]?up)s?([^a-zA-Z]|$)",
    re.IGNORECASE,
)
# The ABSORB and NO-BUILD alternatives are case-sensitive (scoped inline flags): the
# uppercase stem is the tag, a lower-case or title-case inflection is prose.
disp_re = re.compile(
    r"\b(FIX NOW|(?-i:ABSORB)|STANDALONE|(?-i:NO-BUILD)|deferred[- ]to:)",
    re.IGNORECASE,
)
# A candidate target token: a path-ish run; trailing punctuation is trimmed.
TOKEN_RE = re.compile(r"[A-Za-z0-9_./:\-]+")
SLUG_RE = re.compile(r"^[a-z][a-z0-9-]*$")
KEY_RE = re.compile(r"^[0-9]+(?:-[A-Za-z0-9]+)+(?:/[A-Za-z0-9][A-Za-z0-9._-]*)?$")

def resolves(rest):
    # True when some token in the rest of the window names a real on-disk target
    # under the plans root. An optional ":: T-N" suffix (spaced or not) is dropped.
    for tok in TOKEN_RE.findall(rest):
        tok = tok.strip(".,;:)")
        tok = re.sub(r"::T-\d+$", "", tok)
        if not tok or ".." in tok or tok.startswith("/"):
            continue
        if tok.startswith("_inbox/"):
            if tok.endswith(".md") and os.path.isfile(os.path.join(plans_root, tok)):
                return True
        elif SLUG_RE.match(tok):
            if os.path.isfile(os.path.join(plans_root, "_inbox", tok + ".md")):
                return True
        elif KEY_RE.match(tok):
            if os.path.isfile(os.path.join(plans_root, tok, "manifest.json")):
                return True
    return False
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
# A specific disposition TARGET for ABSORB / deferred-to:: a plan slug (above), a
# task id, or an NN/T-n pair. Anything else ("the next pass", "a future session")
# is a floating target — the remember-this pattern wearing a tag.
TASK_ID_RE = re.compile(r"\bT-\d+\b", re.IGNORECASE)
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
    dm = disp_re.search(window)
    if dm:
        # Target discipline: ABSORB / deferred-to: must name WHERE — a plan
        # slug, a task id or an NN/T-n pair, in the text following the tag to
        # the end of the per-item window. A floating target is an undisposed
        # item wearing a tag, so it fails like a missing tag (same severity,
        # same exit contract). FIX NOW and STANDALONE are target-less.
        tag_norm = dm.group(1).upper().replace(" ", "")
        if tag_norm.startswith("ABSORB") or tag_norm.startswith("DEFERRED"):
            rest = window[dm.end():]
            if not (PLAN_SLUG_RE.search(rest) or TASK_ID_RE.search(rest)):
                phrase = dm.group(1).strip()
                trimmed = line.strip().replace('"', '\\"')
                print(f"{i+1}\t{phrase}\t{trimmed}\tunspecific")
                continue
        # Resolvable target: inside the newest session entry only, a STANDALONE /
        # ABSORB / NO-BUILD hit must name a token that exists under the plans root.
        # FIX NOW and deferred-to: never take this test.
        if (tag_norm.startswith("ABSORB") or tag_norm == "STANDALONE" or tag_norm == "NO-BUILD") \
                and span_lo <= i + 1 <= span_hi:
            if not resolves(window[dm.end():]):
                phrase = dm.group(1).strip()
                trimmed = line.strip().replace('"', '\\"')
                print(f"{i+1}\t{phrase}\t{trimmed}\tunresolved")
        continue
    # Emit one record per missing-disposition hit.
    phrase = m.group(2).strip()
    trimmed = line.strip().replace('"', '\\"')
    print(f"{i+1}\t{phrase}\t{trimmed}")
PY
)

  # Launch-prompt length, newest session entry only: warn-level, never counted in
  # MISSING and never part of the exit code.
  if [[ "$LPL_AVAILABLE" == "1" ]]; then
    LP_ROWS="$(launch_prompt_blocks_newest "$file" 2>/dev/null)" || LP_ROWS=""
    while IFS=$'\t' read -r lp_heading lp_words; do
      [[ "$lp_words" =~ ^[0-9]+$ ]] || continue
      [[ "$lp_words" -gt "$LP_MAX" ]] || continue
      LONG=$((LONG + 1))
      emit_finding "handoff-launch-prompt-long" "$file" \
        "heading" "$lp_heading" \
        "words" "$lp_words" \
        "threshold" "$LP_MAX" \
        "target" "$LAUNCH_PROMPT_TARGET_WORDS" \
        "level" "warn"
      LONG_LINES="${LONG_LINES}- ${file} — \"${lp_heading}\" is ${lp_words} words (threshold ${LP_MAX}; target ≤ ${LAUNCH_PROMPT_TARGET_WORDS})"$'\n'
    done <<< "$LP_ROWS"
  fi

  if [[ -z "$RESULT" ]]; then
    continue
  fi

  while IFS=$'\t' read -r lineno phrase matched kind; do
    [[ -z "$lineno" ]] && continue
    MISSING=$((MISSING + 1))
    if [[ "$kind" == "unspecific" ]]; then
      emit_finding "handoff-disposition-target-unspecific" "$file" \
        "line" "$lineno" \
        "phrase" "$phrase" \
        "matched" "$matched" \
        "level" "error"
      REPORT_LINES="${REPORT_LINES}- ${file}:${lineno} — \"${matched}\" disposes via ${phrase} but names no target plan/task (add a plan slug or task id)"$'\n'
    elif [[ "$kind" == "unresolved" ]]; then
      emit_finding "handoff-disposition-target-unresolved" "$file" \
        "line" "$lineno" \
        "phrase" "$phrase" \
        "matched" "$matched" \
        "level" "error"
      REPORT_LINES="${REPORT_LINES}- ${file}:${lineno} — \"${matched}\" disposes via ${phrase} but names no target that resolves under the plans root (an _inbox/<slug>.md, an _inbox/_settled/<slug>.md or a <key>/manifest.json)"$'\n'
    else
      emit_finding "handoff-disposition-missing" "$file" \
        "line" "$lineno" \
        "phrase" "$phrase" \
        "matched" "$matched" \
        "level" "error"
      REPORT_LINES="${REPORT_LINES}- ${file}:${lineno} — \"${phrase}\" needs one of FIX NOW / ABSORB / STANDALONE / NO-BUILD / deferred-to:"$'\n'
    fi
  done <<< "$RESULT"
done <<< "$FILES"

printf "## Handoff Dispositions (%d missing)\n\n" "$MISSING"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- All unresolved language disposed."
fi
if [[ "$LONG" -gt 0 ]]; then
  printf "\n## Launch Prompts (%d over %d words; warn, not counted above)\n\n" "$LONG" "$LP_MAX"
  printf '%s' "$LONG_LINES"
fi

# Non-zero exit if missing — session-close contract blocks on this.
if [[ "$MISSING" -gt 0 ]]; then
  exit 1
fi
exit 0
