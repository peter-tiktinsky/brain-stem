#!/bin/bash
# library-scrub — Deterministic dual-output promotion scrub: workshop research ->
# a universal _library/<topic>/<article>.md AND a plan-SoT _research/ record,
# with bidirectional cross-reference stamps, in one propose/--apply.
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is only a header/env-var path reference (MANIFEST_SCHEMA_PATH); no Draft202012Validator is constructed, so there is no schema-gate degrade path.
# This capability OWNS the full promotion write-orchestration:
#   PROMO-1  identify finalized candidates from workshop content + manifest
#            research_artifacts[] entries with status: finalized.
#   RAW COPY  copy the immutable original into _library/<topic>/_raw/
#            BEFORE scrubbing (read-not-mutate the source) so the article's
#            REQUIRED `sources:` pointers resolve.
#   PROMO-2  deterministic scrub: extract universally-applicable content and
#            strip plan/project-specific detail (task IDs, plan slugs,
#            engagement names, decision dates) into a candidate article;
#            synthesize the `routing:` activation-condition one-liner.
#   PROMO-3  plan-SoT persist: the full plan-specific version lands in
#            <plan>/_research/ AND is declared in the manifest research_artifacts[].
#   PROMO-4  bidirectional stamp within one --apply: the article gains
#            originating_plan: AND the manifest entry gains library_refs:
#            [<topic>/<article>]. Two SEQUENTIAL individually-atomic
#            temp-file + os.replace writes, NOT a transaction — the inter-write
#            crash window is the accepted contract; the library-index re-derive
#            is the one-sided-edge detector (this capability never builds a
#            transaction layer).
#            Convention: originating_plan names its plan by plans-root-relative path (<master>/<sub> for a sub-plan); the bare basename is still accepted.
#   PROMO-6  archive: the workshop originals MOVE to workshop/_archive/. The
#            _library/log.md append half is owned by a separate capability and
#            is NOT written here.
#
# NOVEL BET (advisory-first): scrub quality is unproven. The
# propose phase emits NDJSON candidates and writes NOTHING; the propose diff is
# the human backstop where over-/under-strip is visible.
# --apply is the ONLY writing path. This capability never blocks a prompt and
# never escalates to a harder posture on its own — escalation needs
# observed-failure data.
#
# Block-and-log, never write-and-hope: an empty/malformed scrub
# output is never written; it emits a `scrub-blocked` finding and is skipped.
#
# CENSUS (--census, read-only): lists each research_artifacts[] entry of a
# top-level plan under the plans root (resolved via paths.sh) whose manifest
# status is `completed` and whose entry carries no library_refs, i.e. research
# no promotion has reached. A superseded plan is excluded: its successor
# overruled its conclusions. A sub-plan is not walked, because promotion
# resolves a plan at the top level only. It needs no workshop and writes
# nothing; an unreadable manifest is reported, never skipped silently.
# Promoting a listed entry stays an operator library-scrub run.
#
# LIBRARY PROMOTION (--candidates, --triage, --next, --answer, --claim-answer,
# --mode, --pending):
# a queue that offers each newly completed plan's research for promotion. The
# mode is behavioral.hook_preferences.library_promotion in the user manifest
# (prompt | auto | off; an unset key reads off). While it reads off, --candidates,
# --triage and --next exit 0 with no model call and no write. State lives under
# $CLAUDE_STATE_ROOT/library-promotion/: baseline.json (the plans already
# completed when the mode was switched on, never offered), queue.json (one
# record per candidate: state, triage topic and reason, and the session holding
# its claim) and scan-marker (a manifest older than it is not re-read). Every
# state-writing mode runs under the lockf.sh re-exec on
# $HOOKS_STATE/library-promotion.lock: a contended run exits 0 and logs a skip
# line, and where /usr/bin/lockf is absent the run is inline.
#   --candidates         queue each top-level `completed` plan that is in neither
#                        the baseline nor the queue (no model call). A sub-plan
#                        is never queued: promotion resolves a plan at the top
#                        level only. A mode set by hand, with no baseline yet,
#                        records the baseline on this first run and queues nothing.
#   --triage <plan>      send the plan's canonical research (declared under
#                        _research/, status neither superseded nor deferred, gate
#                        records dropped by path or title) to a small model
#                        (`claude --bare -p --model haiku`, JSON-schema output,
#                        under a watchdog) and record promote or skip plus a
#                        library topic. An empty canonical set is recorded skip
#                        with no call; a failed call leaves the candidate pending
#                        with the reason.
#   --next <session-id>  claim one unclaimed `promote` candidate; print its slug.
#   --claim-answer <session-id> yes|no|always
#                        the auto-mode combined operation: claim one unclaimed
#                        `promote` candidate for the session AND answer it under
#                        one lock acquisition. Contention (lockf timeout) exits 0
#                        having claimed nothing — the skip line records it and the
#                        next Stop re-offers the candidate; a claim is never left
#                        stranded without its answer.
#   --answer <plan> yes|no|always
#                        yes promotes the canonical set through the _research/
#                        source arm: the article lands under the triage topic, no
#                        workshop home is needed, the source is read and never
#                        written or moved (no PROMO-3, no PROMO-6), and both
#                        PROMO-4 stamps are re-read before success is reported.
#                        no records the plan declined; it is never offered again.
#                        always promotes, then sets the mode to auto. yes and
#                        always keep the --apply non-interactive guard.
#   --mode get | --mode set prompt|auto|off
#                        read or write the mode; the first switch to prompt or
#                        auto records the baseline.
#   --pending            list the unanswered candidates: state, claim, topic, reason.
#
# Flow-maintained artifacts (workshop/_archive/, _library/<topic>/_raw/) carry
# maintainer=flow(F-CAP|F-PROMO) with enforcement-owner=librarian — this
# capability is that enforcement owner.
#
# Output Contract (per CLAUDE.md skill-creation rule):
#   Files written (ONLY in --apply mode; propose mode and --census write nothing):
#     1. $LIBRARY/<topic>/_raw/<source>            — immutable provenance copy
#                                                    (written once; never edited)
#     2. $LIBRARY/<topic>/<article>.md             — scrubbed universal article
#                                                    (atomic temp+rename) carrying
#                                                    valid type:reference frontmatter
#     3. <plan>/_research/<article>.md             — full plan-SoT record
#     4. <plan>/manifest.json                      — research_artifacts[] entry
#                                                    gains library_refs[] (atomic)
#     5. $LIBRARY/<topic>/<article>.md frontmatter — gains originating_plan:
#                                                    (the PROMO-4 second atomic write)
#     6. workshop original -> $WORKSHOP/_archive/   — PROMO-6 move
#   The promotion modes write $CLAUDE_STATE_ROOT/library-promotion/* and, for
#     --mode set and --answer always, the user manifest's
#     behavioral.hook_preferences.library_promotion; --answer yes|always writes
#     files 1, 2, 4 and 5 above, never 3 or 6.
#   Schema gated by: schemas/plan-manifest-schema.json (the research_artifacts[]
#     item shape) — the manifest entry is validated as an object BEFORE the
#     library_refs[] stamp write (jsonschema when importable; structural
#     fallback otherwise). The article frontmatter is validated against the
#     registered `reference` type's required-field set
#     (governance/frontmatter-rules.json#types.reference) BEFORE write.
#   Pre-write validation steps:
#     - the scrubbed article body must be non-empty after strip (else block).
#     - the article frontmatter must carry every reference-type required field
#       (read from the registered `reference` type's required[] — the EFFECTIVE
#       registry, which includes the universal typed cohort; see
#       governance/frontmatter-rules.json#types.reference).
#     - the manifest research_artifacts[] entry must validate against the schema.
#     - the workshop home + library home must resolve (workshop-absent ->
#       block-and-log, never crash).
#   Failure mode: BLOCK-AND-LOG. A candidate that fails validation emits a
#     `scrub-blocked` finding and is skipped; no partial write. Never
#     write-and-hope.
#
# NDJSON schema (one line per candidate / event):
#   propose:  { "finding":"library-scrub", "file":"<workshop-source>",
#               "category":"promotion-candidate", "topic":"<topic>",
#               "article":"<article>.md", "plan":"<plan-slug>",
#               "routing":"<activation one-liner>", "raw_sources":"<n>",
#               "scrubbed_terms":"<n>", "valid":true }
#   blocked:  { "finding":"library-scrub", "file":"<workshop-source>",
#               "category":"scrub-blocked", "reason":"...", "valid":false }
#   applied:  { "finding":"library-scrub", "file":"<workshop-source>",
#               "category":"promoted", "topic":"<topic>",
#               "article":"<topic>/<article>.md", "written":"<article path>",
#               "plan_sot":"<_research path>", "archived":"<archive path>" }
#             (the _research/ source arm leaves plan_sot and archived empty)
#   census:  { "finding":"library-scrub", "file":"<research path>",
#               "category":"unpromoted-research", "plan":"<plan-slug>",
#               "ra_id":"<research_artifacts[] id>", "path":"<plan-relative path>" }
#             then one { "finding":"library-scrub", "file":"<plans root>",
#               "category":"unpromoted-research-count", "count":<n> }
#
# Tier: judgment. requires_confirmation: true (propose-then-confirm default;
# --apply is the confirm gate). Cron block: skip-non-interactive.
#
# CLI:
#   library-scrub.sh                      # propose (NDJSON candidates; NO writes)
#   library-scrub.sh --apply              # confirm: write + stamp + archive
#   library-scrub.sh --topic <dir>        # one workshop topic dir (else sweep all)
#   library-scrub.sh --dry-run            # summary counts only; no findings/writes
#   library-scrub.sh --census             # read-only: unpromoted research of completed plans
#   library-scrub.sh --candidates         # queue newly completed plans (no model call)
#   library-scrub.sh --triage <plan>      # small-model promote/skip verdict + topic
#   library-scrub.sh --next <session-id>  # claim one promote candidate; print its slug
#   library-scrub.sh --answer <plan> yes|no|always
#   library-scrub.sh --claim-answer <session-id> yes|no|always
#   library-scrub.sh --mode get | --mode set prompt|auto|off
#   library-scrub.sh --pending            # unanswered candidates with state and reason
#   library-scrub.sh --help               # usage
#
# Env overrides:
#   WORKSHOP_DIR   workshop home (default: $CLAUDE_STATE_ROOT/workshop via
#                  paths.sh — NEVER a hardcoded literal).
#   LIBRARY_DIR    library home (default: $PLANS_DIR/_library).
#   PLANS_DIR      plan tree root (test isolation; resolved via paths.sh).
#   MANIFEST_SCHEMA_PATH   (default: $CLAUDE_HOME/schemas/plan-manifest-schema.json
#                          -> $FOUNDATION_REPO/schemas/plan-manifest-schema.json)
#   FRONTMATTER_RULES_PATH (default: $CLAUDE_HOME/governance/frontmatter-rules.json
#                          -> repo governance/frontmatter-rules.json)
#   FINDINGS_OUTPUT        NDJSON sink (default: stdout)
#   FOUNDATION_TEST_MODE   Bypass the non-interactive guard (test/CI runners).
#   CLAUDECODE             Set by an attended Claude Code session; bypasses the
#                          --apply non-interactive guard (CC is the primary
#                          library-curation surface). A bare cron sweep still blocks.
#   UMR_USER_MANIFEST_PATH user manifest holding the promotion mode (default
#                          $CLAUDE_HOME/user-manifest.json, via user-manifest-read.sh).
#   LIBRARY_PROMOTION_TRIAGE_TIMEOUT  triage watchdog in seconds (default 120).
#
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${CLAUDE_STATE_ROOT:-}" || -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

APPLY="false"
TOPIC=""
DRY_RUN="false"
CENSUS="false"
PROMO_OP=""
PROMO_PLAN=""
PROMO_ARG=""
PROMO_VERDICT=""
# The lockf.sh re-exec runs this script again with the same arguments.
ORIG_ARGS=("$@")

# One library-promotion mode per run.
promo_op() {
  if [[ -n "$PROMO_OP" ]]; then
    echo "library-scrub: one promotion mode per run ('$PROMO_OP' and '$1')" >&2
    exit 2
  fi
  PROMO_OP="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --topic) TOPIC="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --census) CENSUS="true"; shift ;;
    --candidates) promo_op candidates; shift ;;
    --pending) promo_op pending; shift ;;
    --triage|--next)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "library-scrub: $1 takes an argument" >&2; exit 2
      fi
      promo_op "${1#--}"
      if [[ "$1" == "--triage" ]]; then PROMO_PLAN="$2"; else PROMO_ARG="$2"; fi
      shift 2 ;;
    --answer)
      if [[ $# -lt 3 ]]; then
        echo "library-scrub: --answer takes <plan> yes|no|always" >&2; exit 2
      fi
      case "$3" in
        yes|no|always) ;;
        *) echo "library-scrub: --answer takes yes, no or always, not '$3'" >&2; exit 2 ;;
      esac
      promo_op answer; PROMO_PLAN="$2"; PROMO_ARG="$3"; shift 3 ;;
    --claim-answer)
      if [[ $# -lt 3 ]]; then
        echo "library-scrub: --claim-answer takes <session-id> yes|no|always" >&2; exit 2
      fi
      case "$3" in
        yes|no|always) ;;
        *) echo "library-scrub: --claim-answer takes yes, no or always, not '$3'" >&2; exit 2 ;;
      esac
      promo_op claim-answer; PROMO_ARG="$2"; PROMO_VERDICT="$3"; shift 3 ;;
    --mode)
      case "${2:-}" in
        get) promo_op mode-get; shift 2 ;;
        set)
          case "${3:-}" in
            prompt|auto|off) ;;
            *) echo "library-scrub: --mode set takes prompt, auto or off, not '${3:-}'" >&2; exit 2 ;;
          esac
          promo_op mode-set; PROMO_ARG="$3"; shift 3 ;;
        *) echo "library-scrub: --mode takes get, or set prompt|auto|off" >&2; exit 2 ;;
      esac ;;
    # The usage text is the whole leading comment block (it ends at the first empty line).
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "library-scrub: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# A plan argument names a top-level plan directory, nothing else.
case "$PROMO_PLAN" in
  */*|.*|_*) echo "library-scrub: '$PROMO_PLAN' is not a top-level plan slug" >&2; exit 2 ;;
esac

# --- Resolve the three surface homes -----------------------------------------
# Workshop home: $CLAUDE_STATE_ROOT/workshop/ — NEVER hardcoded.
STATE_ROOT_RES="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}"
WORKSHOP_RES="${WORKSHOP_DIR:-$STATE_ROOT_RES/workshop}"
PLANS_RES="${PLANS_DIR:-$HOME/.claude-plans}"
LIBRARY_RES="${LIBRARY_DIR:-$PLANS_RES/_library}"

# --census: the read-only unpromoted-research census. It reads plan manifests
# only, so it runs before the --apply guard and needs no workshop home.
if [[ "$CENSUS" == "true" ]]; then
  if [[ "$APPLY" == "true" ]]; then
    echo "library-scrub: --census is read-only and does not take --apply" >&2
    exit 2
  fi
  python3 - "${PLANS_DIR:-}" <<'PY'
import json
import os
import sys

plans_dir = sys.argv[1]


def emit(payload):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(payload, ensure_ascii=False, separators=(", ", ": "))
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


count = 0
names = []
if plans_dir and os.path.isdir(plans_dir):
    names = sorted(os.listdir(plans_dir))
else:
    emit({"finding": "library-scrub", "file": plans_dir,
          "category": "census-blocked",
          "reason": "plans root absent or unresolved", "valid": False})
for name in names:
    if name.startswith(("_", ".")):
        continue
    manifest_path = os.path.join(plans_dir, name, "manifest.json")
    if not os.path.isfile(manifest_path):
        continue
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, ValueError) as exc:
        emit({"finding": "library-scrub", "file": manifest_path,
              "category": "census-unreadable", "reason": str(exc),
              "valid": False})
        continue
    if not isinstance(manifest, dict) or manifest.get("status") != "completed":
        continue
    for entry in manifest.get("research_artifacts") or []:
        if not isinstance(entry, dict) or entry.get("library_refs"):
            continue
        rel = entry.get("path") or ""
        emit({"finding": "library-scrub",
              "file": os.path.join(plans_dir, name, rel) if rel else manifest_path,
              "category": "unpromoted-research", "plan": name,
              "ra_id": entry.get("id") or "", "path": rel})
        count += 1
emit({"finding": "library-scrub", "file": plans_dir,
      "category": "unpromoted-research-count", "count": count})
PY
  exit 0
fi

# --- Library promotion (see LIBRARY PROMOTION in the header) -----------------
# promo_py <op> [args...]: the queue, baseline, triage and mode operations. Every
# op but pending runs under the lock taken below.
promo_py() {
  local op="$1"
  shift
  python3 - "$op" "$PROMO_STATE" "$PLANS_RES" "$PROMO_PLAN" "$PROMO_ARG" \
            "$PROMO_UM" "$@" <<'PY'
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

op, state_dir, plans_dir, plan, arg, um_path = sys.argv[1:7]
extra = sys.argv[7:]
queue_path = os.path.join(state_dir, "queue.json")
baseline_path = os.path.join(state_dir, "baseline.json")
marker_path = os.path.join(state_dir, "scan-marker")
# Unanswered states; `declined` and `promoted` are answered and never re-offered.
OPEN_STATES = ("pending", "promote", "skip")
GATE_RE = re.compile(r"\bgate[-_ ]?[12]\b", re.IGNORECASE)
TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
VERDICT_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["promote", "skip"]},
        "topic": {"type": "string"},
        "reason": {"type": "string"},
    },
    "required": ["verdict", "topic", "reason"],
    "additionalProperties": False,
}
PROMPT_HEAD = (
    "You decide whether one completed project's research belongs in a shared\n"
    "reference library that other projects read. Answer promote only when the\n"
    "research holds guidance that stays useful outside this project: a reusable\n"
    "technique, a measured finding or a decision rule. Answer skip for status\n"
    "notes, one-off records and anything tied to this project's own files.\n"
    "Return verdict (promote or skip), topic (a short lowercase hyphenated\n"
    "library topic, for example shell-scripting) and a one-sentence reason.\n")
EXCERPT_CHARS = 4000
PROMPT_CAP = 40000


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def say(msg):
    sys.stderr.write("library-scrub: %s\n" % msg)


def flat(text):
    return re.sub(r"\s+", " ", str(text or "")).strip()


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return default
    except (OSError, ValueError) as exc:
        say("unreadable state file %s (%s)" % (path, exc))
        sys.exit(1)


def write_json(path, data):
    """Atomic temp + os.replace, keeping the file's mode. A target made
    read-only is refused, never replaced behind the operator's back."""
    if os.path.exists(path) and not os.access(path, os.W_OK):
        raise OSError("%s is read-only" % path)
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        if os.path.exists(path):
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def load_queue():
    q = load_json(queue_path, {})
    return q if isinstance(q, dict) else {}


def save_queue(q):
    try:
        write_json(queue_path, q)
    except OSError as exc:
        say("queue write failed (%s)" % exc)
        sys.exit(1)


def top_level_completed(since=None):
    """Direct children of the plans root whose manifest status is completed.
    A sub-plan sits under its master, so it is never read here."""
    out = []
    try:
        names = sorted(os.listdir(plans_dir))
    except OSError:
        return out
    for name in names:
        if name.startswith(("_", ".")):
            continue
        mp = os.path.join(plans_dir, name, "manifest.json")
        if not os.path.isfile(mp):
            continue
        try:
            if since is not None and os.stat(mp).st_mtime < since:
                continue
            with open(mp, encoding="utf-8") as fh:
                m = json.load(fh)
        except (OSError, ValueError) as exc:
            say("unreadable manifest %s (%s)" % (mp, exc))
            continue
        if isinstance(m, dict) and m.get("status") == "completed":
            out.append(name)
    return out


def write_baseline():
    write_json(baseline_path, {"plans": top_level_completed(), "recorded_at": now()})


def set_mode(value):
    """Persist behavioral.hook_preferences.library_promotion, keeping every
    other key. The first switch to prompt or auto records the baseline."""
    try:
        with open(um_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        say("no user manifest at %s; the mode was not set" % um_path)
        return 1
    except (OSError, ValueError) as exc:
        say("user manifest unreadable (%s); the mode was not set" % exc)
        return 1
    if not isinstance(data, dict):
        say("user manifest is not a JSON object; the mode was not set")
        return 1
    beh = data.get("behavioral")
    if not isinstance(beh, dict):
        beh = {}
        data["behavioral"] = beh
    prefs = beh.get("hook_preferences")
    if not isinstance(prefs, dict):
        prefs = {}
        beh["hook_preferences"] = prefs
    prefs["library_promotion"] = value
    try:
        write_json(um_path, data)
        if value in ("prompt", "auto") and not os.path.exists(baseline_path):
            write_baseline()
    except OSError as exc:
        say("mode write failed (%s)" % exc)
        return 1
    return 0


def canonical_set(slug):
    """The plan's canonical research: research_artifacts[] entries declared
    under _research/ whose status is neither superseded nor deferred and whose
    file exists, minus gate records (a _gates/ path, or a gate-1 / gate-2 path
    or title): a gate record never carries universal value. None when the
    manifest cannot be read."""
    root = os.path.join(plans_dir, slug)
    try:
        with open(os.path.join(root, "manifest.json"), encoding="utf-8") as fh:
            m = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(m, dict):
        return None
    out = []
    for e in m.get("research_artifacts") or []:
        if not isinstance(e, dict) or not e.get("id"):
            continue
        rel = os.path.normpath(e.get("path") or "")
        parts = rel.split(os.sep)
        if parts[0] != "_research" or len(parts) < 2 or ".." in parts:
            continue
        if e.get("status") in ("superseded", "deferred"):
            continue
        if "_gates" in parts or GATE_RE.search(parts[-1]) \
                or GATE_RE.search(e.get("title") or ""):
            continue
        if not os.path.isfile(os.path.join(root, rel)):
            continue
        out.append(e)
    return out


def call_model(prompt):
    """One small-model verdict. Returns (verdict-dict, None) or (None, error)."""
    exe = shutil.which("claude")
    if not exe:
        return None, "claude CLI not found on PATH"
    try:
        timeout = max(1, int(os.environ.get("LIBRARY_PROMOTION_TRIAGE_TIMEOUT") or 120))
    except ValueError:
        timeout = 120
    argv = [exe, "--bare", "-p", "--model", "haiku", "--output-format", "json",
            "--json-schema", json.dumps(VERDICT_SCHEMA)]
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True)
    except OSError as exc:
        return None, "claude did not start (%s)" % exc
    try:
        out, err = proc.communicate(prompt.encode("utf-8"), timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return None, "no answer within the %ds watchdog" % timeout
    if proc.returncode != 0:
        tail = flat((err.decode("utf-8", "replace").strip().splitlines() or [""])[-1])[:200]
        return None, "claude exited %d%s" % (proc.returncode, (": " + tail) if tail else "")
    try:
        doc = json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        return None, "the output is not JSON"
    if not isinstance(doc, dict) or doc.get("is_error"):
        return None, "claude reported an error"
    v = doc.get("structured_output")
    if not isinstance(v, dict) and isinstance(doc.get("result"), str):
        try:
            v = json.loads(doc["result"])
        except ValueError:
            v = None
    if not isinstance(v, dict) and "verdict" in doc:
        v = doc
    if not isinstance(v, dict) or v.get("verdict") not in ("promote", "skip"):
        return None, "no promote or skip verdict in the output"
    topic = re.sub(r"[^a-z0-9]+", "-", str(v.get("topic") or "").lower()).strip("-")[:60]
    if v["verdict"] == "promote" and not topic:
        return None, "a promote verdict without a topic"
    return {"verdict": v["verdict"], "topic": topic,
            "reason": flat(v.get("reason"))[:300]}, None


def op_candidates():
    t0 = int(time.time())
    baseline = load_json(baseline_path, None)
    if not isinstance(baseline, dict):
        # The mode was set by hand: record the baseline now and offer nothing,
        # so a plan completed before the switch is never offered.
        try:
            write_baseline()
        except OSError as exc:
            say("baseline write failed (%s)" % exc)
            return 1
        new = []
    else:
        base = set(baseline.get("plans") or [])
        q = load_queue()
        since = os.stat(marker_path).st_mtime if os.path.exists(marker_path) else None
        new = [s for s in top_level_completed(since) if s not in base and s not in q]
        if new:
            for s in new:
                q[s] = {"state": "pending", "queued_at": now(), "topic": "",
                        "reason": "awaiting triage", "claimed_by": ""}
            try:
                write_json(queue_path, q)
            except OSError as exc:
                say("queue write failed (%s); the scan marker is unchanged" % exc)
                return 1
    # The marker moves only after the queue write, to the scan's start, so a
    # manifest written during the scan is read again next time.
    os.makedirs(state_dir, exist_ok=True)
    with open(marker_path, "a"):
        pass
    os.utime(marker_path, (t0, t0))
    for s in new:
        print(s)
    return 0


def op_triage():
    q = load_queue()
    rec = q.get(plan)
    if not isinstance(rec, dict):
        say("%s is not a queued candidate" % plan)
        return 1
    if rec.get("state") != "pending":
        say("%s is already triaged (%s)" % (plan, rec.get("state")))
        return 0
    entries = canonical_set(plan)
    if entries is None:
        rec["reason"] = "triage failed: the plan manifest is unreadable"
        save_queue(q)
        say("%s: %s" % (plan, rec["reason"]))
        return 1
    if not entries:
        rec.update(state="skip", topic="", reason="canonical set empty", triaged_at=now())
        save_queue(q)
        print("%s\tskip\t-" % plan)
        return 0
    parts = [PROMPT_HEAD, "\nPlan: %s\n" % plan]
    budget = PROMPT_CAP
    for e in entries:
        if budget <= 0:
            parts.append("\n(further research omitted at the length cap)\n")
            break
        try:
            with open(os.path.join(plans_dir, plan, os.path.normpath(e["path"])),
                      encoding="utf-8", errors="replace") as fh:
                text = fh.read(EXCERPT_CHARS)
        except OSError:
            text = ""
        text = text[:budget]
        budget -= len(text)
        parts.append("\n--- Research %s: %s\nPath: %s\n\n%s\n"
                     % (e.get("id"), flat(e.get("title")), e.get("path"), text))
    verdict, err = call_model("".join(parts))
    if err:
        rec.update(state="pending", reason="triage failed: %s" % err, triaged_at=now())
        save_queue(q)
        say("%s: %s" % (plan, rec["reason"]))
        return 1
    rec.update(state=verdict["verdict"], topic=verdict["topic"],
               reason=verdict["reason"], triaged_at=now())
    save_queue(q)
    print("%s\t%s\t%s" % (plan, rec["state"], rec["topic"] or "-"))
    return 0


def op_next():
    q = load_queue()
    for slug in sorted(q, key=lambda s: (str(q[s].get("queued_at", "")), s)):
        rec = q[slug]
        if isinstance(rec, dict) and rec.get("state") == "promote" \
                and not rec.get("claimed_by"):
            rec["claimed_by"] = arg
            rec["claimed_at"] = now()
            save_queue(q)
            print(slug)
            return 0
    return 0


def op_pending():
    q = load_queue()
    for slug in sorted(q):
        rec = q[slug]
        if not isinstance(rec, dict) or rec.get("state") not in OPEN_STATES:
            continue
        print("%s\tstate=%s\tclaimed=%s\ttopic=%s\treason=%s" % (
            slug, rec.get("state"), flat(rec.get("claimed_by")) or "-",
            flat(rec.get("topic")) or "-", flat(rec.get("reason")) or "-"))
    return 0


def open_record(q):
    rec = q.get(plan)
    if not isinstance(rec, dict) or rec.get("state") not in OPEN_STATES:
        say("%s is not an unanswered candidate" % plan)
        sys.exit(1)
    return rec


def op_answer_skipped():
    q = load_queue()
    rec = q.get(plan)
    if isinstance(rec, dict) and rec.get("state") in OPEN_STATES:
        rec["reason"] = "answer %s skipped (non-interactive)" % arg
        save_queue(q)
    return 0


def op_answer_no():
    q = load_queue()
    rec = open_record(q)
    rec.update(state="declined", reason="declined", answered_at=now(), claimed_by="")
    save_queue(q)
    print("library-scrub: %s declined; it is not offered again" % plan)
    return 0


def op_answer_prepare():
    q = load_queue()
    rec = open_record(q)
    topic = rec.get("topic") or ""
    if not TOPIC_RE.match(topic):
        say("%s has no triage topic; run --triage first" % plan)
        return 1
    entries = canonical_set(plan)
    if not entries:
        say("%s has no canonical research to promote" % plan)
        return 1
    print(topic)
    print(json.dumps([e["id"] for e in entries]))
    return 0


def op_answer_record():
    result_path, scrub_rc = extra[0], extra[1]
    res = load_json(result_path, None)
    try:
        os.unlink(result_path)
    except OSError:
        pass
    q = load_queue()
    rec = open_record(q)
    rc = 0
    if scrub_rc == "0" and isinstance(res, dict) and res.get("promoted") \
            and not res.get("blocked"):
        rec.update(state="promoted", refs=res["promoted"], reason="",
                   answered_at=now(), claimed_by="")
        save_queue(q)
        print("library-scrub: %s promoted (%d article(s)); PROMO-4 stamps verified"
              % (plan, len(res["promoted"])))
    else:
        blocked = (res or {}).get("blocked") if isinstance(res, dict) else None
        rec["reason"] = flat("promotion incomplete: %s" % "; ".join(
            blocked or ["the scrub exited %s" % scrub_rc]))[:300]
        save_queue(q)
        say("%s: %s" % (plan, rec["reason"]))
        rc = 1
    if arg == "always" and set_mode("auto") != 0:
        rc = 1
    return rc


OPS = {
    "candidates": op_candidates, "triage": op_triage, "next": op_next,
    "pending": op_pending, "answer-skipped": op_answer_skipped,
    "answer-no": op_answer_no, "answer-prepare": op_answer_prepare,
    "answer-record": op_answer_record, "mode-set": lambda: set_mode(arg),
}
sys.exit(OPS[op]())
PY
}

RESEARCH_PLAN=""
RESEARCH_TOPIC=""
RESEARCH_IDS=""
RESEARCH_RESULT=""
if [[ -n "$PROMO_OP" ]]; then
  if [[ "$APPLY" == "true" || "$CENSUS" == "true" || "$DRY_RUN" == "true" || -n "$TOPIC" ]]; then
    echo "library-scrub: a promotion mode takes no --apply, --census, --dry-run or --topic" >&2
    exit 2
  fi
  PROMO_STATE="$STATE_ROOT_RES/library-promotion"
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh"; } \
    || { [ -r "$_REPO_LIB/user-manifest-read.sh" ] && source "$_REPO_LIB/user-manifest-read.sh"; } || true
  if command -v _umr_resolve_path >/dev/null 2>&1; then
    PROMO_UM="$(_umr_resolve_path)"
  else
    PROMO_UM="${UMR_USER_MANIFEST_PATH:-${USER_MANIFEST_PATH:-$CLAUDE_HOME_RES/user-manifest.json}}"
  fi
  PROMO_MODE=""
  if command -v umr_get_string >/dev/null 2>&1; then
    PROMO_MODE="$(umr_get_string '.behavioral.hook_preferences.library_promotion' 2>/dev/null || true)"
  fi
  case "$PROMO_MODE" in prompt|auto|off) ;; *) PROMO_MODE="off" ;; esac

  # Read-only modes, and the dormant exit: while the mode reads off the queue
  # modes make no model call and write nothing.
  case "$PROMO_OP" in
    mode-get) printf '%s\n' "$PROMO_MODE"; exit 0 ;;
    pending) promo_py pending; exit 0 ;;
    candidates|triage|next|claim-answer)
      if [[ "$PROMO_MODE" == "off" ]]; then exit 0; fi ;;
  esac

  # State-writing modes: one run at a time under the lockf.sh re-exec.
  if [[ -x /usr/bin/lockf ]]; then
    # shellcheck source=/dev/null
    { [ -r "$CLAUDE_HOME_RES/hooks/lib/lockf.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/lockf.sh"; } \
      || { [ -r "$_REPO_LIB/lockf.sh" ] && source "$_REPO_LIB/lockf.sh"; } || true
    if command -v claude_lockf_reexec >/dev/null 2>&1; then
      PROMO_LOCK_DIR="${HOOKS_STATE:-$STATE_ROOT_RES/hooks-state}"
      mkdir -p "$PROMO_LOCK_DIR"
      claude_lockf_reexec "$PROMO_LOCK_DIR/library-promotion.lock" "${ORIG_ARGS[@]}"
    fi
  fi

  # --claim-answer (the auto-mode combined operation): claim the next promote
  # candidate for this session and answer it under THIS ONE lock acquisition, so
  # a contended run degrades to "never claimed" (the lockf helper's skip line,
  # exit 0) — the next Stop re-offers it — instead of a claimed-but-unanswered
  # record stranded past its one-shot claim. The claim reuses the --next
  # selection (PROMO_ARG carries the session id); an empty answer means nothing
  # was claimable for this session, a clean exit 0. A claimed slug falls through
  # to the answer flow below under the SAME held lock.
  if [[ "$PROMO_OP" == "claim-answer" ]]; then
    _ca_slug="$(promo_py next)"
    if [[ -z "$_ca_slug" ]]; then
      exit 0
    fi
    PROMO_PLAN="$_ca_slug"
    PROMO_ARG="$PROMO_VERDICT"
    PROMO_OP="answer"
  fi
  if [[ "$PROMO_OP" != "answer" ]]; then
    promo_py "$PROMO_OP"
    exit 0
  fi
  if [[ "$PROMO_ARG" == "no" ]]; then
    promo_py answer-no
    exit 0
  fi
  # yes | always write durable content, so they keep the --apply guard below.
  if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${CLAUDECODE:-}" ]] \
     && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
    promo_py answer-skipped
    echo "library-scrub: --answer $PROMO_ARG skipped (non-interactive)" >&2
    exit 0
  fi
  PROMO_PREP="$(promo_py answer-prepare)"
  RESEARCH_PLAN="$PROMO_PLAN"
  RESEARCH_TOPIC="$(printf '%s\n' "$PROMO_PREP" | sed -n '1p')"
  RESEARCH_IDS="$(printf '%s\n' "$PROMO_PREP" | sed -n '2p')"
  RESEARCH_RESULT="$PROMO_STATE/.answer-result.json"
  rm -f "$RESEARCH_RESULT"
  # Falls through to the main body, whose _research/ source arm promotes.
fi

# Judgment-tier non-interactive guard (mirrors memory-globalize.sh /
# memory-hygiene.sh). The propose phase is read-only and harmless, but --apply
# writes durable content; the guard keeps an unattended cron sweep from
# auto-promoting. CLAUDECODE (an attended Claude Code session — the primary
# library-curation operation surface) bypasses the guard so --apply reaches its
# write path there; a bare non-TTY cron sweep (CLAUDECODE unset) still blocks.
if [[ "$APPLY" == "true" ]] && [[ -z "${FOUNDATION_TEST_MODE:-}" ]] \
   && [[ -z "${CLAUDECODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "library-scrub: --apply skipped (non-interactive)" >&2
  exit 0
fi

# workshop-absent -> block-and-log, never crash (the workshop scaffold is a
# separate install unit; this capability degrades gracefully when it is absent).
# The _research/ source arm reads plan research, so it needs no workshop.
if [[ ! -d "$WORKSHOP_RES" && -z "$RESEARCH_PLAN" ]]; then
  if command -v emit_finding >/dev/null 2>&1; then
    emit_finding "library-scrub" "$WORKSHOP_RES" \
      "category" "scrub-blocked" \
      "reason" "workshop home absent (not yet scaffolded); nothing to promote" \
      "valid" "false"
  else
    echo "library-scrub: workshop home absent ($WORKSHOP_RES); nothing to promote" >&2
  fi
  exit 0
fi

# Resolve schemas (live install -> foundation repo).
MANIFEST_SCHEMA="${MANIFEST_SCHEMA_PATH:-}"
if [[ -z "$MANIFEST_SCHEMA" ]]; then
  for c in "$CLAUDE_HOME_RES/schemas/plan-manifest-schema.json" \
           "$_REPO_ROOT/schemas/plan-manifest-schema.json"; do
    if [[ -f "$c" ]]; then MANIFEST_SCHEMA="$c"; break; fi
  done
fi
FRONTMATTER_RULES="${FRONTMATTER_RULES_PATH:-}"
if [[ -z "$FRONTMATTER_RULES" ]]; then
  for c in "$CLAUDE_HOME_RES/governance/frontmatter-rules.json" \
           "$_REPO_ROOT/governance/frontmatter-rules.json"; do
    if [[ -f "$c" ]]; then FRONTMATTER_RULES="$c"; break; fi
  done
fi

# Canonical governance read: the reference-type required-field set
# used for pre-write validation is the EFFECTIVE registry, so route the read
# through the R-52 union-load merger (hooks/lib/foundation-overlay-load.sh) —
# never consume foundation-master / frontmatter-rules.json RAW. Resolve the
# SHIPPED bundle, materialize the merged union once (full-union: same top-level
# shape as foundation-master), and pass it to the python3 body, which reads
# .frontmatter.types.reference.required from the merged view so an adopter's
# overlay-master.json amendments to the reference contract are honored. The loose
# pillar FRONTMATTER_RULES (.types.reference.required shape) stays as the
# dev-repo/no-bundle/explicit-path fallback (loud-safe, never broken).
FM_BUNDLE=""
for c in "$CLAUDE_HOME_RES/governance/foundation-master.json" \
         "$_REPO_ROOT/governance/foundation-master.json"; do
  if [[ -f "$c" ]]; then FM_BUNDLE="$c"; break; fi
done
_OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
[[ -x "$_OVL" ]] || _OVL="$_REPO_ROOT/hooks/lib/foundation-overlay-load.sh"
if [[ -x "$_OVL" && -n "$FM_BUNDLE" && -f "$FM_BUNDLE" ]]; then
  _UNION="$(mktemp 2>/dev/null || true)"
  if [[ -n "$_UNION" ]] && bash "$_OVL" --foundation-path "$FM_BUNDLE" \
        --overlay-path "$(dirname "$FM_BUNDLE")/overlay-master.json" --force-override > "$_UNION" 2>/dev/null \
        && [[ -s "$_UNION" ]]; then
    FM_BUNDLE="$_UNION"; trap 'rm -f "$_UNION"' EXIT
  elif [[ -n "$_UNION" ]]; then rm -f "$_UNION"; fi
fi

# PROMO-6 log half: resolve the library-log-append hook — the SOLE
# appender of the _library/log.md change-log entries (composite). The
# scrub CALLS the appender at PROMO-6; the appender OWNS the write, frontmatter
# seeding, R-33 tolerance, and rotation-threshold detection. NEVER append inline
# here (that would make the scrub a second appender, breaking the disjoint-surface split).
LOG_APPENDER="${LIBRARY_LOG_APPENDER:-}"
if [[ -z "$LOG_APPENDER" ]]; then
  for c in "$CLAUDE_HOME_RES/hooks/library-log-append.sh" \
           "$_REPO_ROOT/hooks/library-log-append.sh"; do
    if [[ -f "$c" ]]; then LOG_APPENDER="$c"; break; fi
  done
fi

# Resolve the SHARED description-derivation helper (hooks/lib/derive-description.sh):
# a promoted article's universal-cohort `description:` is derived through the SAME
# one-derivation-contract helper the forward-governance auto-stamp (post-write-verify.sh)
# and the frontmatter-enforce backfill use, so the three cohort-writing paths agree.
# CLAUDE_HOME-first, repo-lib fallback (dev authoring). Absent -> the python body
# degrades to the concept-H1 fallback (never empty).
DERIVE_DESC="${DERIVE_DESCRIPTION_HELPER:-}"
if [[ -z "$DERIVE_DESC" ]]; then
  for c in "$CLAUDE_HOME_RES/hooks/lib/derive-description.sh" \
           "$_REPO_LIB/derive-description.sh"; do
    if [[ -f "$c" ]]; then DERIVE_DESC="$c"; break; fi
  done
fi

SCRUB_RC=0
python3 - "$WORKSHOP_RES" "$LIBRARY_RES" "$PLANS_RES" "$MANIFEST_SCHEMA" \
          "$FRONTMATTER_RULES" "$APPLY" "$DRY_RUN" "$TOPIC" "$LOG_APPENDER" "$FM_BUNDLE" \
          "$DERIVE_DESC" "$RESEARCH_PLAN" "$RESEARCH_TOPIC" "$RESEARCH_IDS" \
          "$RESEARCH_RESULT" <<'PY' || SCRUB_RC=$?
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import date, datetime, timezone

workshop_dir = sys.argv[1]
library_dir = sys.argv[2]
plans_dir = sys.argv[3]
manifest_schema_path = sys.argv[4]
frontmatter_rules_path = sys.argv[5]
apply_mode = sys.argv[6] == "true"
dry_run = sys.argv[7] == "true"
topic_filter = sys.argv[8]
log_appender = sys.argv[9] if len(sys.argv) > 9 else ""
fm_bundle_path = sys.argv[10] if len(sys.argv) > 10 else ""
derive_desc_helper = sys.argv[11] if len(sys.argv) > 11 else ""
research_plan = sys.argv[12] if len(sys.argv) > 12 else ""
research_topic = sys.argv[13] if len(sys.argv) > 13 else ""
research_ids = json.loads(sys.argv[14]) if len(sys.argv) > 14 and sys.argv[14] else []
research_result = sys.argv[15] if len(sys.argv) > 15 else ""


def append_log_event(action, rel_path, note):
    """PROMO-6 log half: invoke the library-log-append hook (the
    SOLE appender) for one event. The hook OWNS the write/frontmatter/
    rotation; the scrub only CALLS it. Best-effort: a missing/failed appender
    never aborts an otherwise-successful promotion (the log is an audit trail,
    not a promotion precondition)."""
    if not log_appender or not os.path.isfile(log_appender):
        return
    env = dict(os.environ)
    env["LIBRARY_DIR"] = library_dir
    try:
        subprocess.run(["bash", log_appender, action, rel_path, note],
                       env=env, check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

today = date.today().isoformat()
now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---- universal typed cohort (lockstep w/ types.reference.required[]) ----------
# The reference type's required[] gained description/created/id/schema_version.
# A promoted article is a forward-CREATION path, so this capability STAMPS the
# cohort at construction — the article is born compliant AND passes the REF_REQUIRED
# pre-write validation. The three cohort-writing paths agree by construction:
#   - created = TODAY (forward creation; NOT the T-8 git-backfill "never today"
#     rule, which is for pre-existing files).
#   - id = a deterministic readable slug from <topic>/<article> — immutable by
#     construction (re-promotion regenerates the SAME slug; parity with the
#     forward-governance sed-slug + the backfill slugify).
#   - schema_version = the cohort constant, matching the value the forward-governance
#     auto-stamp writes (hooks/post-write-verify.sh add_if_absent schema_version).
#   - description = derived through the SHARED helper (hooks/lib/derive-description.sh).
COHORT_SCHEMA_VERSION = 1


def cohort_slug(text):
    """Deterministic readable slug (parity with the backfill slugify + the
    forward-governance sed slug: lowercase, non-alnum runs -> single hyphen)."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def derive_description(body_text, h1):
    """One-line cohort description via the SHARED helper — one derivation contract
    with forward-governance (post-write-verify.sh) + the backfill (frontmatter-
    enforce.sh). The helper reads a FILE, so compose the article's on-disk body
    (H1 + scrubbed body) into a temp file and call it the way frontmatter-enforce
    does. Falls back to the concept H1 (never empty) when the helper is unavailable
    (sandbox / missing lib)."""
    fallback = (h1 or "").strip()
    if not derive_desc_helper or not os.path.isfile(derive_desc_helper):
        return fallback
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(suffix=".md")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("# %s\n\n%s\n" % (h1, body_text))
        r = subprocess.run(["bash", derive_desc_helper, tmp],
                           capture_output=True, text=True, timeout=25)
        d = ((r.stdout or "").strip().split("\n") or [""])[0].strip()
        return d or fallback
    except Exception:
        return fallback
    finally:
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def emit(payload):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(payload, ensure_ascii=False, separators=(", ", ": "))
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# ---- reference-type required fields (the EFFECTIVE type registry) ------------
# Defensive default mirrors the registered C-FM-ART required set so the
# capability stays correct even if the rules source is unreadable in a sandbox.
# canonical read: the merged union (foundation-master + overlay) is
# materialized by the merger in the shell wrapper and handed in as fm_bundle_path
# (.frontmatter.types.reference shape). Read it FIRST so an adopter's overlay
# amendments to the reference contract are honored; fall back to the loose pillar
# (.types.reference shape) when the bundle/merger is unavailable (dev-repo
# authoring or an explicit FRONTMATTER_RULES_PATH).
REF_REQUIRED = ["type", "tags", "updated", "routing", "sources", "originating_plan",
                "description", "created", "id", "schema_version"]
_ref = None
if fm_bundle_path and os.path.isfile(fm_bundle_path):
    try:
        with open(fm_bundle_path, encoding="utf-8") as fh:
            _fb = json.load(fh)
        _ref = (_fb.get("frontmatter", {}) or {}).get("types", {}).get("reference")
    except (OSError, json.JSONDecodeError):
        _ref = None
if not (_ref and _ref.get("required")) and frontmatter_rules_path \
        and os.path.isfile(frontmatter_rules_path):
    try:
        with open(frontmatter_rules_path, encoding="utf-8") as fh:
            _fr = json.load(fh)
        _ref = _fr.get("types", {}).get("reference")
    except (OSError, json.JSONDecodeError):
        _ref = None
if _ref and _ref.get("required"):
    REF_REQUIRED = list(_ref["required"])


# ---- optional jsonschema gate for the manifest research_artifacts[] item ----
_ra_item_schema = None
if manifest_schema_path and os.path.isfile(manifest_schema_path):
    try:
        with open(manifest_schema_path, encoding="utf-8") as fh:
            _ms = json.load(fh)
        _ra = _ms.get("properties", {}).get("research_artifacts", {})
        _ra_item_schema = _ra.get("items")
    except (OSError, json.JSONDecodeError):
        _ra_item_schema = None

_ra_validator = None
if _ra_item_schema is not None:
    try:
        import jsonschema  # type: ignore
        _ra_validator = jsonschema.Draft7Validator(_ra_item_schema)
    except ImportError:
        _ra_validator = None


def validate_ra_item(item):
    """Validate one research_artifacts[] entry. jsonschema when available;
    structural fallback to the required-key set otherwise."""
    if _ra_validator is not None:
        errs = sorted(_ra_validator.iter_errors(item), key=lambda e: list(e.path))
        if errs:
            return False, "plan-manifest-schema: %s" % errs[0].message
        return True, ""
    for k in ("id", "title", "status", "path"):
        if not item.get(k):
            return False, "structural: research_artifacts item missing '%s'" % k
    if item.get("status") not in ("active", "finalized", "deferred"):
        return False, "structural: status not in active|finalized|deferred"
    return True, ""


# ---- plan-id / topic parsing -------------------------------------------------
# Workshop routing is by directory naming convention ONLY:
#   <topic>/            -> general (no plan-id; library-only output)
#   <topic>-<plan-id>/  -> plan-specific (the -<plan-id> suffix routes the
#                          plan-SoT output to <plan-id>/_research/).
# A plan-id is a plan-tree dir that exists under PLANS_DIR.
def split_topic_plan(dirname):
    """Return (topic, plan_slug-or-None). The plan-id is the longest trailing
    hyphen-delimited suffix that names an existing plan dir under plans_dir."""
    parts = dirname.split("-")
    for cut in range(1, len(parts)):
        candidate = "-".join(parts[cut:])
        if candidate and os.path.isdir(os.path.join(plans_dir, candidate)):
            topic = "-".join(parts[:cut])
            if topic:
                return topic, candidate
    return dirname, None


# ---- deterministic scrub -----------------------------------------------------
# Strip plan/project-specific detail: task IDs, plan slugs,
# engagement names, decision dates. Deterministic, line-oriented. Over-/under-
# strip is VISIBLE in the propose diff before any write — the
# human backstop for the novel bet.
TASK_ID_RE = re.compile(r'\b[TM]-\d+\b|\bSP-?\d+\b|\bADR-\d+\b|\bRA-\d+\b')
PLAN_SLUG_RE = re.compile(r'\bplan\s*\d+\b', re.IGNORECASE)
DATE_RE = re.compile(r'\b\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z?)?\b')
# A leading in-document section index / auto-TOC is FORBIDDEN in article bodies
# (body shape) — drop a generated "## Contents" / "## Table of Contents"
# block if the captured source carries one.
TOC_HEADING_RE = re.compile(r'^\s*#{1,6}\s+(contents|table of contents|toc)\s*$',
                            re.IGNORECASE)


def scrub_body(text, plan_slug, engagement_terms):
    """Return (scrubbed_body, n_terms_removed). Deterministic strip."""
    removed = 0
    out_lines = []
    in_toc = False
    for line in text.split("\n"):
        if TOC_HEADING_RE.match(line):
            in_toc = True
            removed += 1
            continue
        if in_toc:
            # a TOC block runs until the next non-list, non-blank heading
            if line.strip() == "" or line.lstrip().startswith(("-", "*", "1.")):
                continue
            in_toc = False
        orig = line
        line, n1 = TASK_ID_RE.subn("", line)
        line, n2 = PLAN_SLUG_RE.subn("", line)
        line, n3 = DATE_RE.subn("", line)
        n4 = 0
        if plan_slug:
            line, n4 = re.subn(re.escape(plan_slug), "", line)
        n5 = 0
        for term in engagement_terms:
            if term:
                line, c = re.subn(re.escape(term), "", line)
                n5 += c
        removed += n1 + n2 + n3 + n4 + n5
        # collapse the whitespace the strip left behind
        if line != orig:
            line = re.sub(r'[ \t]{2,}', " ", line).rstrip()
        out_lines.append(line)
    body = "\n".join(out_lines).strip()
    return body, removed


def synthesize_routing(topic, article_name, body):
    """Synthesize the routing: the per-article activation-condition one-liner.
    Deterministic: 'Read when working on <article-concept> in the <topic>
    domain.' — derived from the topic + article concept name, not a build ref.
    library-index's Description column consumes this as its FIRST derivation source."""
    concept = article_name.replace("-", " ").replace("_", " ").strip()
    topic_h = topic.replace("-", " ").replace("_", " ").strip()
    routing = "Read when working on %s in the %s domain." % (concept, topic_h)
    return routing[:200]


def derive_h1(body, article_name):
    """The article H1 is the concept name (body scaffold)."""
    return article_name.replace("-", " ").replace("_", " ").strip().title()


def build_article(topic, article_name, scrubbed_body, routing, raw_sources,
                  tags, plan_slug, description, created, article_id,
                  schema_version):
    """Compose the article markdown: reference frontmatter -> H1 = concept ->
    synthesized body -> [[name]] bare sibling wikilinks at the foot.
    NO leading in-document section index, NO auto-TOC."""
    h1 = derive_h1(scrubbed_body, article_name)
    fm = []
    fm.append("---")
    fm.append("type: reference")
    fm.append("tags: [%s]" % ", ".join(tags))
    fm.append("updated: %s" % today)
    fm.append("routing: %s" % json.dumps(routing, ensure_ascii=False))
    # sources: pointers to the _raw/ originals this article was synthesized from.
    fm.append("sources:")
    for s in raw_sources:
        fm.append("  - %s" % json.dumps("_raw/" + s, ensure_ascii=False))
    # originating_plan is REQUIRED unconditionally (C-FM-ART). build_article is
    # only ever reached with a resolved promoting plan; the no-plan path is
    # block-and-logged before construction.
    fm.append("originating_plan: %s" % plan_slug)
    # universal typed cohort (required[] gained these four). json.dumps on the
    # description mirrors the routing line's valid-YAML double-quoting idiom.
    fm.append("description: %s" % json.dumps(description, ensure_ascii=False))
    fm.append("created: %s" % created)
    fm.append("id: %s" % article_id)
    fm.append("schema_version: %s" % schema_version)
    fm.append("---")
    # C-FM-ART body scaffold: a SINGLE H1 = the concept name. If the captured
    # source carried its own leading H1, drop it so the synthesized concept H1
    # is the sole top-level heading (no duplicate-H1, no leading section index).
    body_lines = scrubbed_body.split("\n")
    while body_lines and body_lines[0].strip() == "":
        body_lines.pop(0)
    if body_lines and re.match(r'^\s*#\s+', body_lines[0]):
        body_lines.pop(0)
        while body_lines and body_lines[0].strip() == "":
            body_lines.pop(0)
    scrubbed_body = "\n".join(body_lines)
    body = "\n".join(fm) + "\n\n# %s\n\n" % h1 + scrubbed_body + "\n"
    return body, h1


def article_frontmatter_dict(topic, article_name, routing, raw_sources, tags,
                             plan_slug, description, created, article_id,
                             schema_version):
    """The frontmatter as a dict for pre-write required-field validation."""
    fm = {
        "type": "reference",
        "tags": tags,
        "updated": today,
        "routing": routing,
        "sources": ["_raw/" + s for s in raw_sources],
    }
    # originating_plan is REQUIRED unconditionally (C-FM-ART); a missing/empty
    # plan_slug surfaces in the required-field check and block-and-logs.
    fm["originating_plan"] = plan_slug
    # universal typed cohort — stamped so the REF_REQUIRED pre-write check (which
    # now reads these four from the effective registry) passes AND the promoted
    # article is born cohort-compliant.
    fm["description"] = description
    fm["created"] = created
    fm["id"] = article_id
    fm["schema_version"] = schema_version
    return fm


def atomic_write(target, content):
    d = os.path.dirname(target)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def stamp_manifest_library_refs(manifest_path, ra_id, ref):
    """PROMO-4 second-class write: the manifest research_artifacts[] entry with
    id==ra_id gains library_refs += [ref]. Individually atomic temp+replace.
    Returns True on stamp, False if the entry/field could not be located."""
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return False
    ra = data.get("research_artifacts")
    if not isinstance(ra, list):
        return False
    stamped = False
    for entry in ra:
        if isinstance(entry, dict) and entry.get("id") == ra_id:
            refs = entry.get("library_refs")
            if not isinstance(refs, list):
                refs = []
            if ref not in refs:
                refs.append(ref)
            entry["library_refs"] = refs
            stamped = True
            break
    if not stamped:
        return False
    content = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    atomic_write(manifest_path, content)
    return True


def read_finalized_ra(manifest_path):
    """PROMO-1 manifest half: research_artifacts[] entries with status
    finalized, keyed by basename of their path for matching to workshop files."""
    out = {}
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return out
    for entry in data.get("research_artifacts", []) or []:
        if isinstance(entry, dict) and entry.get("status") == "finalized":
            p = entry.get("path", "")
            if p:
                out[os.path.basename(p)] = entry
    return out


def first_nonempty_line(text):
    for line in text.split("\n"):
        if line.strip():
            return line.strip()
    return ""


counts = {
    "topics": 0, "candidates": 0, "promoted": 0, "blocked": 0,
    "skipped_empty": 0, "skipped_archive": 0,
}


def article_origin(path):
    """The originating_plan: value in an article's frontmatter; None when the
    article does not exist, "" when it carries no such line."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    for line in (m.group(1) if m else "").split("\n"):
        if line.startswith("originating_plan:"):
            return line.split(":", 1)[1].strip()
    return ""


def manifest_has_ref(manifest_path, ra_id, ref):
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return False
    for entry in data.get("research_artifacts") or []:
        if isinstance(entry, dict) and entry.get("id") == ra_id:
            return ref in (entry.get("library_refs") or [])
    return False


# ---- _research/ source arm (--answer yes|always) -----------------------------
# The promotion queue's accept step. The source is a plan's own declared
# _research/ research, the topic is the triage verdict's, and no workshop home
# is needed. The source is read and never written or moved: PROMO-3 and PROMO-6
# do not run. The article write and the manifest stamp are the PROMO-4 pair,
# and both are re-read before a promotion counts.
if research_plan:
    import filecmp

    result = {"promoted": [], "blocked": []}

    def research_blocked(src, reason):
        result["blocked"].append("%s: %s" % (src, reason))
        emit({"finding": "library-scrub", "file": src, "category": "scrub-blocked",
              "reason": reason, "valid": False})

    plan_root = os.path.join(plans_dir, research_plan)
    manifest_path = os.path.join(plan_root, "manifest.json")
    entries = {}
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            for e in json.load(fh).get("research_artifacts") or []:
                if isinstance(e, dict) and e.get("id"):
                    entries[e["id"]] = e
    except (OSError, ValueError, AttributeError) as exc:
        research_blocked(manifest_path, "plan manifest unreadable (%s)" % exc)
    engagement_terms = [seg for seg in research_plan.split("-")
                        if seg and not seg.isdigit() and len(seg) > 3]
    tags = ["#%s/library" % research_topic]
    if not research_ids:
        research_blocked(manifest_path, "no canonical research to promote")
    for rid in research_ids:
        entry = entries.get(rid)
        if entry is None:
            research_blocked(rid, "no research_artifacts[] entry with this id")
            continue
        rel = os.path.normpath(entry.get("path") or "")
        src_path = os.path.join(plan_root, rel)
        src = os.path.basename(rel)
        if rel.split(os.sep)[0] != "_research" or ".." in rel.split(os.sep) \
                or not src.endswith(".md"):
            research_blocked(src_path, "not a _research/ markdown entry")
            continue
        try:
            with open(src_path, encoding="utf-8") as fh:
                raw_text = fh.read()
        except OSError as exc:
            research_blocked(src_path, "source unreadable (%s)" % exc)
            continue
        # A leading ordinal (01-, 02-) orders a plan's own research; the
        # article name drops it.
        article_name = re.sub(r"^\d+-", "", src[:-3]) or src[:-3]
        scrubbed, _n_removed = scrub_body(raw_text, research_plan, engagement_terms)
        if not scrubbed.strip():
            research_blocked(src_path, "scrub produced an empty article body")
            continue
        routing = synthesize_routing(research_topic, article_name, scrubbed)
        cohort_description = derive_description(
            scrubbed, derive_h1(scrubbed, article_name))
        cohort_id = cohort_slug("%s/%s" % (research_topic, article_name)) or "note"
        art_fm = article_frontmatter_dict(
            research_topic, article_name, routing, [src], tags, research_plan,
            cohort_description, today, cohort_id, COHORT_SCHEMA_VERSION)
        missing = [k for k in REF_REQUIRED
                   if k not in art_fm or art_fm[k] in (None, "", [])]
        if missing:
            research_blocked(src_path, "article frontmatter missing required "
                                       "field(s): %s" % ",".join(missing))
            continue
        ok, reason = validate_ra_item(entry)
        if not ok:
            research_blocked(src_path, "manifest research_artifacts[] entry "
                                       "invalid: %s" % reason)
            continue
        topic_root = os.path.join(library_dir, research_topic)
        article_path = os.path.join(topic_root, article_name + ".md")
        raw_target = os.path.join(topic_root, "_raw", src)
        ref = "%s/%s" % (research_topic, article_name)
        origin = article_origin(article_path)
        if origin not in (None, research_plan):
            research_blocked(src_path, "article %s.md already exists from %s"
                                       % (ref, origin or "an unknown plan"))
            continue
        if os.path.exists(raw_target) and not filecmp.cmp(src_path, raw_target,
                                                          shallow=False):
            research_blocked(src_path, "%s/_raw/%s holds a different source"
                                       % (research_topic, src))
            continue
        try:
            os.makedirs(os.path.dirname(raw_target), exist_ok=True)
            if not os.path.exists(raw_target):
                shutil.copy2(src_path, raw_target)
            article_md, _h1 = build_article(
                research_topic, article_name, scrubbed, routing, [src], tags,
                research_plan, cohort_description, today, cohort_id,
                COHORT_SCHEMA_VERSION)
            atomic_write(article_path, article_md)
        except OSError as exc:
            research_blocked(src_path, "library write failed (%s)" % exc)
            continue
        try:
            stamp_manifest_library_refs(manifest_path, rid, ref)
        except OSError:
            pass
        if not (manifest_has_ref(manifest_path, rid, ref)
                and article_origin(article_path) == research_plan):
            research_blocked(src_path, "PROMO-4 stamps not verified (manifest "
                                       "library_refs or article originating_plan)")
            continue
        append_log_event("INGEST", "%s/_raw/%s" % (research_topic, src),
                         "promoted provenance original (CAP-3)")
        append_log_event("PROMOTE", ref + ".md", "promoted from %s" % research_plan)
        result["promoted"].append(ref)
        emit({"finding": "library-scrub", "file": src_path, "category": "promoted",
              "topic": research_topic, "article": ref + ".md",
              "written": article_path, "plan_sot": "", "archived": ""})
    if research_result:
        atomic_write(research_result, json.dumps(result) + "\n")
    sys.exit(0 if result["promoted"] and not result["blocked"] else 3)

if not os.path.isdir(workshop_dir):
    # already guarded in the shell wrapper, but stay defensive.
    print("library-scrub: workshop dir absent", file=sys.stderr)
    sys.exit(0)

topic_dirs = sorted(
    d for d in os.listdir(workshop_dir)
    if os.path.isdir(os.path.join(workshop_dir, d)) and d != "_archive"
)
if topic_filter:
    topic_dirs = [d for d in topic_dirs if d == topic_filter]

archive_root = os.path.join(workshop_dir, "_archive")

for tdir in topic_dirs:
    counts["topics"] += 1
    tpath = os.path.join(workshop_dir, tdir)
    topic, plan_slug = split_topic_plan(tdir)

    manifest_path = None
    finalized_ra = {}
    if plan_slug:
        manifest_path = os.path.join(plans_dir, plan_slug, "manifest.json")
        if os.path.isfile(manifest_path):
            finalized_ra = read_finalized_ra(manifest_path)

    # engagement-name strip terms: derive deterministically from the plan slug's
    # non-numeric segments (so plan-specific monikers strip out of the article).
    engagement_terms = []
    if plan_slug:
        for seg in plan_slug.split("-"):
            if seg and not seg.isdigit() and len(seg) > 3:
                engagement_terms.append(seg)

    # Each loose .md in the topic dir is a promotion candidate (loose
    # markdown). _raw is provenance, not a candidate source on its own.
    src_files = sorted(
        f for f in os.listdir(tpath)
        if f.endswith(".md") and os.path.isfile(os.path.join(tpath, f))
    )

    for src in src_files:
        src_path = os.path.join(tpath, src)
        article_name = src[:-3]  # drop .md

        # PROMO-1: a plan-specific candidate must be declared finalized in the
        # manifest research_artifacts[] (declaration is the selectivity gate).
        # A topic with no resolvable promoting plan is block-and-logged below
        # (C-FM-ART requires originating_plan unconditionally) — it never
        # promotes on workshop presence alone.
        ra_entry = None
        if plan_slug:
            ra_entry = finalized_ra.get(src)
            if ra_entry is None:
                # not a declared-finalized artifact: skip silently in propose
                # (it stays in the workshop until declared).
                continue

        try:
            with open(src_path, encoding="utf-8") as fh:
                raw_text = fh.read()
        except OSError:
            continue

        # RAW COPY: the immutable original is the _raw/ provenance source.
        raw_sources = [src]

        scrubbed, n_removed = scrub_body(raw_text, plan_slug, engagement_terms)

        # empty-article output -> block-and-log, never write.
        if not scrubbed.strip():
            counts["blocked"] += 1
            counts["skipped_empty"] += 1
            if not dry_run:
                emit({
                    "finding": "library-scrub", "file": src,
                    "category": "scrub-blocked",
                    "reason": "scrub produced an empty article body (over-strip "
                              "or empty source); blocked-and-logged",
                    "valid": False,
                })
            continue

        # C-OUT: no promoting plan resolvable -> block-and-log,
        # never write a plan-less article. C-FM-ART requires originating_plan
        # unconditionally; the SoT defines no plan-less write. A topic whose
        # directory carries no -<plan-id> suffix (or whose suffix names no plan
        # dir under PLANS_DIR) has no resolvable promoting plan, so the article
        # is blocked rather than written without its required back-pointer.
        if not plan_slug:
            counts["blocked"] += 1
            if not dry_run:
                emit({
                    "finding": "library-scrub", "file": src,
                    "category": "scrub-blocked",
                    "reason": "no promoting plan resolvable for topic '%s' "
                              "(C-FM-ART requires originating_plan; the F-PROMO "
                              "chain is plan-bound by construction)" % topic,
                    "valid": False,
                })
            continue

        # default tags: deterministic, R-47-compliant, topic-scoped.
        tags = ["#%s/%s" % (topic, "library")]
        routing = synthesize_routing(topic, article_name, scrubbed)

        # universal typed cohort (forward-CREATION path): stamp created=today, an
        # immutable readable id slug from <topic>/<article>, the cohort schema_version,
        # and a description via the SHARED helper. Computed BEFORE validation so the
        # REF_REQUIRED check (which now includes these four) passes in BOTH propose
        # and --apply, and the promoted article is born compliant.
        cohort_h1 = derive_h1(scrubbed, article_name)
        cohort_description = derive_description(scrubbed, cohort_h1)
        cohort_created = today
        cohort_id = cohort_slug("%s/%s" % (topic, article_name)) or "note"

        # pre-write validation: article frontmatter required-field set.
        # C-FM-ART: originating_plan is REQUIRED unconditionally — the
        # F-PROMO chain is plan-bound by construction (PROMO-3 persists to
        # <plan>/_research/, PROMO-4 stamps that plan's manifest), so EVERY
        # promotion has a promoting plan whose slug is the value. There is no
        # plan-less write. A topic that cannot resolve a promoting plan
        # block-and-logs below (C-OUT), never writes the article
        # without the field.
        art_fm = article_frontmatter_dict(
            topic, article_name, routing, raw_sources, tags, plan_slug,
            cohort_description, cohort_created, cohort_id, COHORT_SCHEMA_VERSION)
        missing = [k for k in REF_REQUIRED if k not in art_fm or art_fm[k] in (None, "", [])]
        if missing:
            counts["blocked"] += 1
            if not dry_run:
                emit({
                    "finding": "library-scrub", "file": src,
                    "category": "scrub-blocked",
                    "reason": "article frontmatter missing required field(s): %s"
                              % ",".join(missing),
                    "valid": False,
                })
            continue

        # pre-write validation: the manifest research_artifacts[] entry shape
        # (only for plan-specific promotions that will stamp library_refs).
        if ra_entry is not None:
            ok, reason = validate_ra_item(ra_entry)
            if not ok:
                counts["blocked"] += 1
                if not dry_run:
                    emit({
                        "finding": "library-scrub", "file": src,
                        "category": "scrub-blocked",
                        "reason": "manifest research_artifacts[] entry invalid: %s"
                                  % reason,
                        "valid": False,
                    })
                continue

        counts["candidates"] += 1
        ref = "%s/%s" % (topic, article_name)  # <topic>/<article> stamp form

        if not apply_mode:
            if not dry_run:
                emit({
                    "finding": "library-scrub", "file": src,
                    "category": "promotion-candidate", "topic": topic,
                    "article": article_name + ".md",
                    "plan": plan_slug or "",
                    "routing": routing,
                    "raw_sources": str(len(raw_sources)),
                    "scrubbed_terms": str(n_removed),
                    "valid": True,
                })
            continue

        # ===================== --apply: the write chain ======================
        topic_root = os.path.join(library_dir, topic)
        raw_root = os.path.join(topic_root, "_raw")
        article_path = os.path.join(topic_root, article_name + ".md")

        # RAW COPY: copy the immutable original into _library/<topic>/_raw/
        # BEFORE scrubbing the article (read-not-mutate the source). Written once.
        os.makedirs(raw_root, exist_ok=True)
        raw_target = os.path.join(raw_root, src)
        if not os.path.exists(raw_target):
            shutil.copy2(src_path, raw_target)

        # PROMO-2: write the scrubbed universal article (atomic).
        article_md, _h1 = build_article(
            topic, article_name, scrubbed, routing, raw_sources, tags, plan_slug,
            cohort_description, cohort_created, cohort_id, COHORT_SCHEMA_VERSION)
        atomic_write(article_path, article_md)

        plan_sot_path = ""
        if plan_slug:
            # PROMO-3: plan-SoT persist — the FULL plan-specific version lands in
            # <plan>/_research/ (the un-scrubbed original is the plan SoT).
            research_dir = os.path.join(plans_dir, plan_slug, "_research")
            plan_sot_path = os.path.join(research_dir, src)
            atomic_write(plan_sot_path, raw_text)

            # PROMO-4: bidirectional stamp — two SEQUENTIAL individually-atomic
            # writes, NOT a transaction (the accepted crash-window contract; the
            # library-index re-derive is the one-sided-edge detector).
            #   (1) the article already carries originating_plan: from build_article
            #       above (its first atomic write).
            #   (2) the manifest entry gains library_refs: [<topic>/<article>].
            if manifest_path and ra_entry is not None:
                stamp_manifest_library_refs(manifest_path, ra_entry.get("id"), ref)

        # PROMO-6: archive — MOVE the workshop original to workshop/_archive/.
        archive_topic = os.path.join(archive_root, tdir)
        os.makedirs(archive_topic, exist_ok=True)
        archive_target = os.path.join(archive_topic, src)
        shutil.move(src_path, archive_target)

        # PROMO-6 log half: record the promotion in _library/log.md via
        # the SOLE appender hook. Event->ACTION mapping (the seam
        # contract): the _raw/ immutable provenance copy is an INGEST; the
        # universal article is a PROMOTE. Both paths are <topic>/<article>.md form
        # so the library-index staleness reader keys the topic from segment 0.
        article_rel = "%s/%s.md" % (topic, article_name)
        raw_rel = "%s/_raw/%s" % (topic, src)
        append_log_event("INGEST", raw_rel,
                         "promoted provenance original (CAP-3)")
        append_log_event("PROMOTE", article_rel,
                         "promoted from %s" % plan_slug)

        counts["promoted"] += 1
        if not dry_run:
            emit({
                "finding": "library-scrub", "file": src,
                "category": "promoted", "topic": topic,
                "article": ref + ".md", "written": article_path,
                "plan_sot": plan_sot_path,
                "archived": archive_target,
            })

if dry_run:
    mode = "apply" if apply_mode else "propose"
    print("library-scrub: dry-run summary (mode=%s, topics=%d)" % (
        mode, counts["topics"]), file=sys.stderr)
    print("  candidates=%d promoted=%d blocked=%d (empty=%d)" % (
        counts["candidates"], counts["promoted"], counts["blocked"],
        counts["skipped_empty"]), file=sys.stderr)
PY

# --answer yes|always: record the _research/ arm's outcome on the candidate.
if [[ -n "$RESEARCH_PLAN" ]]; then
  promo_py answer-record "$RESEARCH_RESULT" "$SCRUB_RC"
  exit 0
fi
[[ "$SCRUB_RC" -eq 0 ]] || exit "$SCRUB_RC"
exit 0
