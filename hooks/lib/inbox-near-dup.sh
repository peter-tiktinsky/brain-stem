#!/bin/bash
# inbox-near-dup.sh — score inbox idea notes for near-duplicates.
#
# A pair of notes is scored on three signals:
#   cite     a shared `path:line` cite (a file-like token followed by `:<digits>`, in the
#            title or body of both notes)
#   stem     a shared slug stem: the two slugs start with the same N hyphen tokens
#            (N = inbox.near_duplicate.stem_min_tokens, never below 2)
#   overlap  token overlap (Jaccard) of title + `## Idea` section; lines that are the
#            idea-note template's placeholder text are excluded
# A pair is flagged when its overlap reaches inbox.near_duplicate.overlap_min, or when it
# shares a cite or a stem and its overlap reaches corroborated_overlap_min (a shared cite or
# stem alone never flags: the live inbox holds many unrelated notes that cite the same file
# line or open with the same two words). The overlap signal counts only when the pair shares
# at least inbox.near_duplicate.min_shared_tokens tokens, and a note carrying a `resolution:`
# is not open, so it is never scored among the flat notes. The thresholds live in the plans pillar
# (inbox.near_duplicate), set by a calibration run over the real inbox; an overlay re-tunes
# them by a plain deep-merge.
#
# CLI:
#   inbox-near-dup.sh --candidates --slug <slug> --title <title> [--body-file <path>]
#                     [--inbox <dir>]
#       print one line per OPEN flat note that matches the proposed capture, the proposed
#       note itself excluded:  <slug><TAB>cite=<n> stem=<n> overlap=<0.00>
#   inbox-near-dup.sh --pairs [--include-settled] [--all] [--inbox <dir>]
#       print one line per flagged pair of notes:
#       <slugA><TAB><slugB><TAB>cite=<n> stem=<n> overlap=<0.00>
#       --include-settled also scores notes under <inbox>/_settled; --all prints every
#       pair with any signal, flagged or not, for calibration.
#   Threshold overrides for calibration: --overlap-min <f> --corroborated-overlap-min <f>
#   inbox-near-dup.sh --help
#
# Notes carrying a `distinct_from:` line naming the other slug, or named by the other's
# `distinct_from:`, are linked: --pairs omits a linked pair. --candidates is not
# suppressed by a link (a capture states its own --distinct-from).
#
# Exit codes: 0 done (matches or not), 2 usage error, 5 the thresholds cannot be read.
# The inbox defaults to the plans root's `_inbox` (PLANS_ROOT, else $HOME/.claude-plans).
# Rules are resolved as backlog-index resolves them: PLANS_RULES_PATH, else the loose pillar
# under $CLAUDE_HOME/governance, else the merged `.plans` view from foundation-overlay-load.sh.
#
# Bash 3.2 clean per R-23. Argv-based Python per R-24.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"

MODE=""; SLUG=""; TITLE=""; BODY_FILE=""; INBOX=""; INCL=0; ALL=0; OV_MIN=""; COR_OV_MIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --candidates) MODE="candidates"; shift ;;
    --pairs) MODE="pairs"; shift ;;
    --include-settled) INCL=1; shift ;;
    --all) ALL=1; shift ;;
    --slug|--title|--body-file|--inbox|--overlap-min|--corroborated-overlap-min)
      if [ $# -lt 2 ]; then echo "inbox-near-dup: $1 needs a value" >&2; exit 2; fi
      case "$1" in
        --slug) SLUG="$2" ;; --title) TITLE="$2" ;; --body-file) BODY_FILE="$2" ;;
        --inbox) INBOX="$2" ;; --overlap-min) OV_MIN="$2" ;; --corroborated-overlap-min) COR_OV_MIN="$2" ;;
      esac
      shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "inbox-near-dup: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "inbox-near-dup: usage: inbox-near-dup.sh --candidates --slug S --title T | --pairs [--include-settled]" >&2
  exit 2
fi
if [ "$MODE" = "candidates" ] && { [ -z "$SLUG" ] || [ -z "$TITLE" ]; }; then
  echo "inbox-near-dup: --candidates needs --slug and --title" >&2; exit 2
fi
[ -n "$INBOX" ] || INBOX="${PLANS_ROOT:-$HOME/.claude-plans}/_inbox"

RULES_PATH="${PLANS_RULES_PATH:-}"
if [ -z "$RULES_PATH" ] && [ -f "$CLAUDE_HOME_RES/governance/plans-rules.json" ]; then
  RULES_PATH="$CLAUDE_HOME_RES/governance/plans-rules.json"
fi
_rt=""
if [ -z "$RULES_PATH" ] || [ ! -f "$RULES_PATH" ]; then
  for _loader in \
    "$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh" \
    "$SCRIPT_DIR/foundation-overlay-load.sh"; do
    [ -x "$_loader" ] || continue
    _rt="$(mktemp 2>/dev/null)" || break
    if bash "$_loader" --query '.plans' --force-override > "$_rt" 2>/dev/null \
         && [ -s "$_rt" ] && [ "$(head -c4 "$_rt" 2>/dev/null)" != null ]; then
      RULES_PATH="$_rt"; break
    fi
    rm -f "$_rt"; _rt=""
  done
fi
trap '[ -z "$_rt" ] || rm -f "$_rt"' EXIT

TEMPLATE=""
for _t in "$SCRIPT_DIR/../../templates/idea-note-template.md" "$CLAUDE_HOME_RES/templates/idea-note-template.md"; do
  [ -f "$_t" ] && { TEMPLATE="$_t"; break; }
done

python3 - "$MODE" "$INBOX" "$INCL" "$ALL" "$SLUG" "$TITLE" "$BODY_FILE" "${RULES_PATH:-}" \
  "$OV_MIN" "$COR_OV_MIN" "$TEMPLATE" <<'PY'
import json
import os
import re
import sys

(mode, inbox, incl, show_all, slug, title, body_file, rules_path,
 ov_arg, cor_ov_arg, template) = sys.argv[1:12]

STOP = set("""the and for that this with from are was were has have had not but its into over
under then than when what which will would should could can may also each every any all one
two our out use used using via per own more most other some such only both been being their
there these those they them his her she you your""".split())


def die(code, msg):
    print("inbox-near-dup: %s" % msg, file=sys.stderr)
    sys.exit(code)


cfg = {}
if rules_path:
    try:
        with open(rules_path, encoding="utf-8") as fh:
            cfg = json.load(fh).get("inbox", {}).get("near_duplicate", {}) or {}
    except (OSError, ValueError, AttributeError):
        cfg = {}


def threshold(arg, key):
    if arg != "":
        try:
            return float(arg)
        except ValueError:
            die(2, "threshold '%s' is not a number" % arg)
    val = cfg.get(key)
    if isinstance(val, bool) or not isinstance(val, (int, float)):
        die(5, "inbox.near_duplicate.%s is not readable (set it in the plans pillar)" % key)
    return float(val)


overlap_min = threshold(ov_arg, "overlap_min")
corroborated_overlap_min = threshold(cor_ov_arg, "corroborated_overlap_min")
stem_tokens = cfg.get("stem_min_tokens", 2)
if isinstance(stem_tokens, bool) or not isinstance(stem_tokens, int) or stem_tokens < 2:
    stem_tokens = 2
min_shared = cfg.get("min_shared_tokens", 3)
if isinstance(min_shared, bool) or not isinstance(min_shared, int) or min_shared < 1:
    min_shared = 3

placeholders = set()
if template and os.path.isfile(template):
    with open(template, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln.startswith("(") and ln.endswith(")"):
                placeholders.add(ln)
# A capture's own stub body keeps `{...}` placeholder lines until the note grows.
PH_RE = re.compile(r"^(\((What is it\?|What problem|Anything else)|\{.*\}$)")

CITE_RE = re.compile(r"[A-Za-z0-9_./-]+\.[A-Za-z0-9]{1,5}:[0-9]+")
TOK_RE = re.compile(r"[a-z0-9]+")


def parse(text):
    """Return (frontmatter dict, body)."""
    fm = {}
    body = text
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            for ln in text[3:end].splitlines():
                m = re.match(r"^([A-Za-z_]+):\s*(.*)$", ln)
                if m:
                    fm[m.group(1)] = m.group(2).strip()
            body = text[end + 4:]
    return fm, body


def idea_section(body):
    out = []
    on = False
    for ln in body.splitlines():
        if re.match(r"^##\s", ln):
            if on:
                break
            on = bool(re.match(r"^##\s+Idea\s*$", ln))
            continue
        if on:
            s = ln.strip()
            if s in placeholders or PH_RE.match(s):
                continue
            out.append(ln)
    return "\n".join(out)


def tokens(text):
    return set(t for t in TOK_RE.findall(text.lower())
               if len(t) >= 3 and t not in STOP and not t.isdigit())


def make(sl, text):
    fm, body = parse(text)
    ttl = fm.get("title", "").strip().strip("\"'")
    idea = idea_section(body)
    blob = ttl + "\n" + body
    return {
        "slug": sl,
        "toks": tokens(ttl + "\n" + idea),
        "cites": set(CITE_RE.findall(blob)),
        "distinct": set(x.strip() for x in re.split(r"[,\s]+", fm.get("distinct_from", "")) if x.strip()),
        "stem": sl.split("-"),
    }


def load_dir(d, settled):
    out = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    for n in names:
        if not n.endswith(".md") or n.startswith("_"):
            continue
        try:
            with open(os.path.join(d, n), encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        fm, _ = parse(text)
        if fm.get("type", "idea") != "idea":
            continue
        if not settled and fm.get("resolution", "").strip():
            continue  # a resolved note is not open, wherever it still sits
        rec = make(n[:-3], text)
        rec["settled"] = settled
        out.append(rec)
    return out


def score(a, b):
    cite = len(a["cites"] & b["cites"])
    k = 0
    for x, y in zip(a["stem"], b["stem"]):
        if x != y:
            break
        k += 1
    stem = k if k >= stem_tokens else 0
    union = a["toks"] | b["toks"]
    shared = len(a["toks"] & b["toks"])
    # Two short titles sharing one word score high on Jaccard alone; the overlap signal
    # counts only when the pair shares at least min_shared_tokens tokens.
    ov = (shared / float(len(union))) if union and shared >= min_shared else 0.0
    return cite, stem, ov


def flagged(cite, stem, ov):
    return ((cite >= 1 or stem) and ov >= corroborated_overlap_min) or ov >= overlap_min


def fmt(cite, stem, ov):
    return "cite=%d stem=%d overlap=%.3f" % (cite, stem, ov)


flat = load_dir(inbox, False)
if mode == "candidates":
    body = ""
    if body_file:
        try:
            with open(body_file, encoding="utf-8") as fh:
                body = fh.read()
        except OSError as exc:
            die(2, "cannot read --body-file (%s)" % exc)
    me = make(slug, "---\ntitle: %s\ntype: idea\n---\n%s" % (title, body))
    for o in flat:
        if o["slug"] == slug:
            continue
        c, s, ov = score(me, o)
        if flagged(c, s, ov):
            print("%s\t%s" % (o["slug"], fmt(c, s, ov)))
    sys.exit(0)

pool = flat + (load_dir(os.path.join(inbox, "_settled"), True) if incl == "1" else [])
for i in range(len(pool)):
    for j in range(i + 1, len(pool)):
        a, b = pool[i], pool[j]
        c, s, ov = score(a, b)
        if show_all != "1":
            if not flagged(c, s, ov):
                continue
            if b["slug"] in a["distinct"] or a["slug"] in b["distinct"]:
                continue
        elif not (c or s or ov > 0):
            continue
        print("%s\t%s\t%s" % (a["slug"], b["slug"], fmt(c, s, ov)))
PY
