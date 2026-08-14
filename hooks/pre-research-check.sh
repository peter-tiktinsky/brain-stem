#!/bin/bash
# Hook: pre-research-check — UserPromptSubmit pre-research library coverage signal.
#
# ADVISORY-ONLY (inject, never block). This hook detects research intent in the
# user's prompt and, when the three-surface library has coverage, INJECTS a
# COMPRESSED coverage signal as additionalContext so research is not duplicated.
# It NEVER blocks, refuses, gates, or escalates: there is no deny path, no Stop
# path, no PreToolUse path in this body. Advisory-default is the contract — this
# is NOT a structural enforcement mechanism. (Advisory-only by contract;
# gate G-G RATIFIED advisory-first.)
#
# This is the highest-risk novel bet in the three-surface set: zero attested
# production instances exist anywhere. It therefore ships advisory-only
# and escalates to any harder posture ONLY on observed forgotten-research /
# dead-pointer data — never on schedule. To make that data observable, every
# injection appends one lightweight JSONL counter line under the hook state dir
# (see MEASUREMENT below); escalation needs DATA, not opinion.
#
# Behavior (the five numbered steps below):
#   PRE-1  Detect research intent (keyword/heuristic over the prompt) and read
#          the library root _index.md from disk within the hook timeout. Library
#          absent / index absent / non-research prompt -> SILENT no-op allow
#          (zero output noise — an adopter without a library sees nothing).
#   PRE-2  Inject covered topics, each topic's last-updated age, a stale flag,
#          and a read-pointer. NEVER the full index body.
#   PRE-3  Velocity-tiered staleness: per-article revalidation_interval_days with
#          a 90-day fallback when undeclared; on a stale match present the
#          three-way choice validate / use-as-is / research-fresh.
#   PRE-4  #1 PRE-CAP ACTIVE compression: as coverage grows, WINNOW the injected
#            signal to the top matching topics — fires INDEPENDENT of and BEFORE
#            the byte cap (a large library never dumps every topic).
#          #2 AT-CAP fallback: if the assembled signal exceeds the 9,728-byte
#            additionalContext cap (hooks/lib/registry.sh format_output_allow
#            MAX), replace it with a single-line `librarian library-index --query
#            <topic>` pointer so the inline signal survives below the cap.
#   PRE-5  Advisory-only: inject, never block; no Stop escalation.
#
# Degraded portable layer: a generic global-rules library-check entry (the
# rules/ fallback seeded by install.sh — NOT authored here) backs this hook so coverage
# is preserved even when the hook is absent. This hook only needs to degrade
# gracefully (silent allow) when the library is absent.
#
# Seam note: the at-cap pointer text `librarian library-index --query <topic>`
# (the SoT-worded contract) resolves to library-index.sh's
# read-only --query mode (the index-query keystone, which accepts
# --topic / --dry-run / --query / --help). The pointer is emitted verbatim as a
# human-facing string; this hook does not invoke or modify library-index.sh.
#
# MEASUREMENT: on injection, append one JSONL line to
#   $SESSION_STATE_ROOT/pre-research-check/observations.jsonl
# recording {ts, topics_total, topics_matched, stale_matched, winnowed,
# at_cap_fallback}. Best-effort, never fatal — the signal is what makes a future
# escalation decision data-backed instead of speculative.
#
# Fail-open throughout: any error -> silent exit 0, never blocks. Bash 3.2 clean
# (R-23). $SCRIPT_DIR/lib sourcing (no literal $HOME/.claude path in the body).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# registry.sh sources paths.sh (PLANS_DIR, CLAUDE_STATE_ROOT, SESSION_STATE_ROOT)
# and exposes format_output_allow. Graceful-degrade if absent.
# shellcheck source=/dev/null
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh"

# Read the prompt up front. No prompt -> nothing to detect.
# BOUNDED capture: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook hangs with zero output. The timeout
# is on EVERY read and each line accumulates as it arrives, so a stream that keeps
# delivering is never truncated; blank lines are PRESERVED and the trailing-newline
# trim reproduces `$(cat)` exactly, so the payload reaches jq byte-identical.
# HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
# The two reference implementations under skills/librarian/capabilities/ are NOT
# equivalent and this is neither: handoff-disposition-check.sh re-arms per read but
# DROPS blank lines; rename-cascade.sh bounds only the FIRST read, then free-runs an
# unbounded `cat`. This is the byte-preserving form the other hook drains carry.
INPUT=""
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE || [ -n "$_STDIN_LINE" ]; do
    INPUT="${INPUT}${_STDIN_LINE}"$'\n'
    _STDIN_LINE=""
  done
  while [ "${INPUT%$'\n'}" != "$INPUT" ]; do INPUT="${INPUT%$'\n'}"; done
  unset _STDIN_WAIT _STDIN_LINE
fi
PROMPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || true)"
fi
[ -n "$PROMPT" ] || exit 0

# --- intent detection ----------------------------------------
# Keyword/heuristic: lowercase the prompt and match research-intent markers. A
# missed detection is non-fatal — the F-RECON reconciliation at promotion still
# catches duplication (failure mode: no silent loss).
PROMPT_LC="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"
RESEARCH_RE='research|investigat|look(ing)? into|dig(ging)? into|deep[ -]dive|explore|figure out|find out|look up|best practice|compare|evaluate|prior art|what.?s the best|how (do|does|should|can|would)|state of the art|survey|background on'
if ! printf '%s' "$PROMPT_LC" | grep -Eq "$RESEARCH_RE"; then
  exit 0   # not a research-intent prompt -> silent no-op allow (PRE-1)
fi

# --- library home resolution (mirrors library-index.sh exactly) -------------
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
LIBRARY="${LIBRARY_DIR:-${PLANS_DIR:-$PLANS_ROOT}/_library}"
case "$LIBRARY" in */) LIBRARY="${LIBRARY%/}" ;; esac
ROOT_INDEX="$LIBRARY/_index.md"

# Coverage sources (PRE-1): the _library corpus AND the
# binder research-index (_projects/<spoke>/research-index.md) + per-plan
# <plan>/_research/ homes — all rooted under $PLANS_ROOT. Proceed when the plans
# tree exists; a fully-absent plans tree -> silent no-op allow (graceful). The
# python enumeration is fail-open PER-SOURCE, so a missing _library simply yields
# no library topics (and if no source yields coverage, the emit stays silent).
[ -d "$PLANS_ROOT" ] || exit 0

# --- measurement sink ---------------------------------------
OBS_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}/pre-research-check"
OBS_FILE="$OBS_DIR/observations.jsonl"

# --- build the compressed coverage signal (winnow + age + cap) --------------
# All of: covered-topic enumeration, per-article age + stale flag (PRE-2/3),
# pre-cap winnowing to top-matching topics (PRE-4 #1), and the at-cap one-line
# pointer fallback are computed in one argv-based python3 pass
# (R-24). The hook stays advisory: it only PRINTS the assembled signal; the
# emission path below is allow-only.
SIGNAL="$(python3 - "$LIBRARY" "$ROOT_INDEX" "$PROMPT_LC" "$OBS_FILE" "$PLANS_ROOT" <<'PY'
import json, os, re, sys
from datetime import date, datetime, timezone

library, root_index, prompt_lc, obs_file, plans_root = sys.argv[1:6]
today = date.today()
DEFAULT_INTERVAL = 90            # fallback when undeclared
# The at-cap fallback uses the shipped 9,728B format_output_allow MAX
# (hooks/lib/registry.sh).
# PRE_RESEARCH_CAP_OVERRIDE is a TEST-ONLY hook to drive the at-cap boundary
# deterministically without pathological fixtures; production never sets it, so
# the cap is the shipped 9,728B value by default.
try:
    CAP = int(os.environ.get("PRE_RESEARCH_CAP_OVERRIDE", "") or 9728)
except Exception:
    CAP = 9728
WINNOW_TOP = 6                   # PRE-4 #1: top-matching topics ceiling

STOP = set("the a an of to for and or in on with vs how do does should can "
           "what when why is are research about into best practice".split())

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

def read(path, n=8192):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read(n)
    except Exception:
        return ""

def age_days(updated):
    try:
        d = datetime.strptime(updated.strip(), "%Y-%m-%d").date()
        return (today - d).days
    except Exception:
        return None

def to_int(v, default):
    try:
        return int(str(v).strip())
    except Exception:
        return default

# prompt keyword set for relevance scoring (PRE-4 #1 winnowing)
words = set(re.findall(r"[a-z0-9][a-z0-9-]{2,}", prompt_lc)) - STOP

# --- enumerate covered topics (article dirs under the library) --------------
topics = []
try:
    entries = sorted(os.listdir(library))
except Exception:
    entries = []
for t in entries:
    d = os.path.join(library, t)
    if not os.path.isdir(d) or t.startswith(".") or t.startswith("_") or t == "log-archive":
        continue
    arts = []
    try:
        files = sorted(os.listdir(d))
    except Exception:
        files = []
    for f in files:
        if not f.endswith(".md") or f == "_index.md" or f.startswith("."):
            continue
        p = os.path.join(d, f)
        fm = parse_fm(read(p))
        upd = fm.get("updated", "")
        interval = to_int(fm.get("revalidation_interval_days"), DEFAULT_INTERVAL)
        routing = (fm.get("routing") or "").strip().strip('"')
        ad = age_days(upd)
        stale = (ad is not None and ad > interval)
        arts.append({"name": f[:-3], "updated": upd, "age": ad,
                     "interval": interval, "stale": stale, "routing": routing})
    if not arts:
        continue
    # topic relevance score: keyword overlap with topic name + member routing
    hay = (t.replace("-", " ") + " " + " ".join(a["routing"].lower() for a in arts))
    haywords = set(re.findall(r"[a-z0-9][a-z0-9-]{2,}", hay))
    score = len(words & haywords)
    # topic-level last-updated age = freshest member (smallest age)
    ages = [a["age"] for a in arts if a["age"] is not None]
    topic_age = min(ages) if ages else None
    topic_stale = any(a["stale"] for a in arts)
    topics.append({"topic": t, "n": len(arts), "score": score,
                   "age": topic_age, "stale": topic_stale, "arts": arts})

# --- also enumerate binder + per-plan _research/ coverage ---
# The library is not the only research home. A binder research-index
# (_projects/<spoke>/research-index.md) and per-plan <plan>/_research/*.md dirs
# (the 140/11 research_artifacts[] + 152/T-6 canonical home) carry research
# coverage too; enumerate them so a research-intent prompt covered ONLY by binder
# or plan research still gets a dedup signal. Advisory-only: these join the topics
# list and flow through the SAME allow-only emit path. Fail-open (any error skips
# the source); no deny/Stop path is added (inject-or-silent is the hook contract).
# (bash-3.2 R-23: this heredoc body stays apostrophe/backtick-free.)
projects_dir = os.path.join(plans_root, "_projects")
try:
    _spokes = sorted(os.listdir(projects_dir))
except Exception:
    _spokes = []
for _sp in _spokes:
    if _sp.startswith("."):
        continue
    _ri = os.path.join(projects_dir, _sp, "research-index.md")
    if not os.path.isfile(_ri):
        continue
    _body = read(_ri, 4096)
    _fm = parse_fm(_body)
    _ad = age_days(_fm.get("updated", ""))
    _hay = _sp.replace("-", " ") + " " + _body.lower()
    _haywords = set(re.findall(r"[a-z0-9][a-z0-9-]{2,}", _hay))
    _score = len(words & _haywords)
    topics.append({"topic": "binder:%s" % _sp, "n": 1, "score": _score,
                   "age": _ad, "stale": False, "arts": [], "kind": "binder"})

# per-plan <plan>/_research/*.md (skip _-prefixed roster dirs like _library/_projects)
try:
    _plans = sorted(os.listdir(plans_root))
except Exception:
    _plans = []
for _pl in _plans:
    if _pl.startswith(".") or _pl.startswith("_"):
        continue
    _rdir = os.path.join(plans_root, _pl, "_research")
    if not os.path.isdir(_rdir):
        continue
    try:
        _rfiles = [f for f in sorted(os.listdir(_rdir))
                   if f.endswith(".md") and f != "_index.md" and not f.startswith(".")]
    except Exception:
        _rfiles = []
    if not _rfiles:
        continue
    _hay = _pl.replace("-", " ") + " " + " ".join(f[:-3].replace("-", " ") for f in _rfiles)
    _haywords = set(re.findall(r"[a-z0-9][a-z0-9-]{2,}", _hay))
    _score = len(words & _haywords)
    topics.append({"topic": "plan-research:%s" % _pl, "n": len(_rfiles), "score": _score,
                   "age": None, "stale": False, "arts": [], "kind": "plan"})

if not topics:
    sys.exit(0)   # no covered topics -> emit nothing (silent allow)

topics_total = len(topics)

# --- pre-cap ACTIVE winnowing to top-matching topics ------------------------
# Order by relevance score (desc), then freshest, then name. WINNOW to the top
# matching subset whenever coverage exceeds the WINNOW_TOP ceiling — independent
# of and BEFORE the byte cap.
topics.sort(key=lambda x: (-x["score"], (x["age"] if x["age"] is not None else 1 << 30), x["topic"]))
winnowed = topics_total > WINNOW_TOP
shown = topics[:WINNOW_TOP] if winnowed else topics
stale_matched = sum(1 for t in shown if t["stale"])

def age_str(d):
    if d is None:
        return "age unknown"
    if d == 0:
        return "updated today"
    if d == 1:
        return "1 day ago"
    return "%d days ago" % d

# --- assemble the compressed signal -----------------------------------------
lines = []
lines.append("LIBRARY COVERAGE — existing research may cover this prompt "
             "(advisory; not a directive).")
for t in shown:
    flag = " [STALE]" if t["stale"] else ""
    lines.append("- %s (%d article%s, %s)%s"
                 % (t["topic"], t["n"], "" if t["n"] == 1 else "s",
                    age_str(t["age"]), flag))
# PRE-3: three-way choice presented ONLY when a shown topic is stale
if stale_matched:
    lines.append("")
    lines.append("One or more covered topics are STALE (past their "
                 "revalidation interval). For each stale topic, choose: "
                 "(1) validate the existing article, (2) use it as-is, or "
                 "(3) research fresh.")
# PRE-2: read-pointer, never the full index body
lines.append("")
lines.append("Before researching, read _library/<topic>/_index.md for the "
             "topic(s) above.")
if winnowed:
    lines.append("(%d of %d covered topics shown — top matches only; run "
                 "`librarian library-index` for the full roster.)"
                 % (len(shown), topics_total))

signal = "\n".join(lines)

# --- at-cap fallback --------------------------------------------------------
# If the assembled signal exceeds the cap, replace it with a single-line query
# pointer so the inline signal survives below the cap (never overflow-to-file).
at_cap = False
if len(signal.encode("utf-8")) > CAP:
    at_cap = True
    top_topic = shown[0]["topic"] if shown else "<topic>"
    signal = ("LIBRARY COVERAGE — existing research likely covers this; run "
              "`librarian library-index --query %s` for the inline roster."
              % top_topic)

# --- MEASUREMENT: best-effort observation line --------------
try:
    os.makedirs(os.path.dirname(obs_file), exist_ok=True)
    rec = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "topics_total": topics_total, "topics_shown": len(shown),
           "stale_matched": stale_matched, "winnowed": winnowed,
           "at_cap_fallback": at_cap}
    with open(obs_file, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec) + "\n")
except Exception:
    pass

sys.stdout.write(signal)
PY
)" || SIGNAL=""

# Nothing assembled (no covered topics, or any error) -> silent no-op allow.
[ -n "$SIGNAL" ] || exit 0

# --- emit (advisory-only) ----------------------------------------------------
# ALLOW-only injection through the shipped format_output_allow (enforces the
# 9,728B cap the at-cap fallback above already respects). There is NO deny path
# in this hook — it can only inject or stay silent.
if declare -F format_output_allow >/dev/null 2>&1; then
  format_output_allow "UserPromptSubmit" "$SIGNAL" || true
fi
exit 0
