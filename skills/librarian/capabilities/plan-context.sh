#!/bin/bash
# plan-context — read-only loader for one plan's working context, by selector.
#
# An agent resuming a plan needs a slice of it, not the whole tree: one task, one spec
# section, the canonical research, the live decisions, the last session. This verb prints
# that slice from the plan's own files and writes nothing.
#
#   plan-context <plan>                      the plan map (below)
#   plan-context <plan> --task T-n           the task's title, status, description, ACs,
#                                            depends_on, file_references, sot_refs, and each
#                                            optional context_refs[] entry resolved:
#                                              <file>#<heading>  that heading's section, up to
#                                                                the next heading of equal or
#                                                                higher level (file relative
#                                                                to the plan dir)
#                                              ADR-NN            the decision file
#   plan-context <plan> --section "<heading>" [--file <rel>]
#                                            that section of spec.md (or of <rel>)
#   plan-context <plan> --canon              the canonical research: research_artifacts[]
#                                            entries whose path starts with `_research/` and
#                                            whose status is neither superseded nor deferred
#   plan-context <plan> --decisions          decision_records[] entries not superseded
#   plan-context <plan> --handoff latest|<N> the newest entry, or the newest N entries
#   plan-context <plan> --handoff --since <YYYY-MM-DD>
#                                            the entries dated on or after that day
#
# <plan> is a plan dir, or a slug resolved under the plans root (a top-level plan, else a
# sub-plan one level down). Handoff entries come from the spoke's handoff ledger
# (_projects/<project>/handoff-ledger.jsonl, written by plan-handoff-index) when it holds rows
# for the plan, else from handoff.md read with hooks/lib/handoff-recognizer.sh. Either way
# the entry text is sliced from handoff.md.
#
# The plan map (no selector) prints six lines: the canonical research, the count of
# `- <FORK>: ruled` lines in handoff.md, the _gates/ file count, the assets[] rows plus the
# top-level entries outside the managed set (plans-rules.json :: plan_folder_managed_set;
# sub-plan dirs, the architecture_path target, dotfiles and assets[] rows excused), whether
# manifest.json carries capability_touch, and the newest handoff entry's heading and Next line.
#
# Output Contract:
#   Files written: none (read-only).
#   stdout: the selected text, at most 30,000 characters. Longer output is cut and its last
#     line names a narrower selector.
#   Schema: the plan's manifest.json (tasks[], research_artifacts[], decision_records[],
#     assets[]); governance/plans-rules.json :: plan_folder_managed_set, read with
#     PLANS_RULES_PATH first, then the .plans slot of the merged foundation + overlay view,
#     then the raw bundle, then the repo pillar.
#   Validation: a missing plan, task, heading, file or ADR exits 1 naming it; a usage error
#     exits 2.
#   Failure mode: report-and-exit; never writes.
#
# Env overrides (testing):
#   PLANS_ROOT / PLANS_DIR   the plans root (else hooks/lib/paths.sh)
#   CLAUDE_HOME              where the recognizer lib and the composed master are read first
#   FOUNDATION_MASTER_PATH   the composed master
#   PLANS_RULES_PATH         a plans pillar (raw or bundled) read before the master
#
# Bash 3.2 clean. Data reaches Python through argv and the environment, never a piped stdin.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [ -z "${PLANS_ROOT:-}" ] && [ -z "${PLANS_DIR:-}" ]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
PLANS_ROOT="${PLANS_ROOT%/}"

# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/handoff-recognizer.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/handoff-recognizer.sh"; } \
  || { [ -r "$_REPO_LIB/handoff-recognizer.sh" ] && source "$_REPO_LIB/handoff-recognizer.sh"; } \
  || { echo "plan-context: hooks/lib/handoff-recognizer.sh unreadable under $CLAUDE_HOME_RES and $_REPO_LIB" >&2; exit 2; }

PLAN=""
MODE="map"
ARG=""
FILE_REL="spec.md"
SINCE=""
USAGE='plan-context: usage: plan-context <plan> [--task T-n | --section "<heading>" [--file <rel>] | --canon | --decisions | --handoff latest|<N>|--since <YYYY-MM-DD>]'
while [ $# -gt 0 ]; do
  case "$1" in
    --task)      MODE="task"; ARG="${2:-}"; shift 2 ;;
    --section)   MODE="section"; ARG="${2:-}"; shift 2 ;;
    --file)      FILE_REL="${2:-}"; shift 2 ;;
    --canon)     MODE="canon"; shift ;;
    --decisions) MODE="decisions"; shift ;;
    --handoff)
      MODE="handoff"
      case "${2:-}" in
        --since) SINCE="${3:-}"; shift 3 ;;
        "")      ARG="latest"; shift ;;
        *)       ARG="$2"; shift 2 ;;
      esac ;;
    --since)     MODE="handoff"; SINCE="${2:-}"; shift 2 ;;
    -h|--help)   awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*)          echo "plan-context: unknown flag '$1'" >&2; echo "$USAGE" >&2; exit 2 ;;
    *)
      if [ -n "$PLAN" ]; then echo "$USAGE" >&2; exit 2; fi
      PLAN="$1"; shift ;;
  esac
done
[ -n "$PLAN" ] || { echo "$USAGE" >&2; exit 2; }

# The managed set, for the plan map: PLANS_RULES_PATH, then the merged foundation + overlay
# view (hooks/lib/foundation-overlay-load.sh, the union-load primitive), then the raw bundle,
# then the repo pillar. Unreadable: the map says so on its assets line.
MSET=""
if [ "$MODE" = "map" ]; then
  if [ -n "${PLANS_RULES_PATH:-}" ] && [ -f "$PLANS_RULES_PATH" ]; then
    MSET=$(jq -c '(.plans.plan_folder_managed_set // .plan_folder_managed_set) // empty' "$PLANS_RULES_PATH" 2>/dev/null || true)
  fi
  MASTER="${FOUNDATION_MASTER_PATH:-$CLAUDE_HOME_RES/governance/foundation-master.json}"
  if [ -z "$MSET" ] && [ -f "$MASTER" ]; then
    _OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
    [ -x "$_OVL" ] || _OVL="$_REPO_LIB/foundation-overlay-load.sh"
    if [ -x "$_OVL" ]; then
      # The loader's exit code and stderr are kept, never discarded: a failed or degraded overlay
      # load is named on stderr (one line, with its rc) before the raw-bundle fallback below.
      _OVL_ERR="$(mktemp -t plan-context-ovl-XXXXXX)"; _OVL_RC=0
      _OVL_OUT=$(bash "$_OVL" --foundation-path "$MASTER" \
          --overlay-path "$(dirname "$MASTER")/overlay-master.json" --force-override 2>"$_OVL_ERR") || _OVL_RC=$?
      if [ "$_OVL_RC" -ne 0 ] || [ -s "$_OVL_ERR" ]; then
        echo "plan-context: overlay load failed (rc $_OVL_RC): $(grep -v '^[[:space:]]*$' "$_OVL_ERR" | tail -1)" >&2
      fi
      rm -f "$_OVL_ERR"
      # swallow-ok: reports=none a loader failure is reported on stderr above; this jq only extracts one optional key from the output the loader just produced with exit 0, and an absent key reads as empty and falls back to the master read below
      [ "$_OVL_RC" -eq 0 ] && MSET=$(printf '%s' "$_OVL_OUT" \
          | jq -c '.plans.plan_folder_managed_set // empty' 2>/dev/null || true)
    fi
    [ -n "$MSET" ] || MSET=$(jq -c '.plans.plan_folder_managed_set // empty' "$MASTER" 2>/dev/null || true)
  fi
  if [ -z "$MSET" ] && [ -f "$_REPO_ROOT/governance/plans-rules.json" ]; then
    MSET=$(jq -c '.plan_folder_managed_set // empty' "$_REPO_ROOT/governance/plans-rules.json" 2>/dev/null || true)
  fi
fi

python3 - "$PLANS_ROOT" "$PLAN" "$MODE" "$ARG" "$FILE_REL" "$SINCE" "${MSET:-null}" <<'PY'
import glob, json, os, re, sys

plans_root, plan_arg, mode, arg, file_rel, since, mset_s = sys.argv[1:8]
LIMIT = 30000
HEADING_RE = re.compile(os.environ["HANDOFF_SESSION_HEADING_PY"], re.IGNORECASE)
DATE_RE = re.compile(os.environ["HANDOFF_DATE_PY"])
NUM_RE = re.compile(os.environ["HANDOFF_SESSION_NUM_PY"], re.IGNORECASE)
NEXT_RE = re.compile(r"^\s*\**\s*next session\b", re.IGNORECASE)
RULED_RE = re.compile(r"^- \S+: ruled ")
MD_HEAD = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")


def miss(msg):
    sys.stderr.write("plan-context: %s\n" % msg)
    sys.exit(1)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# --- the plan ---------------------------------------------------------------------------
def resolve_plan(p):
    if os.path.isfile(os.path.join(p, "manifest.json")):
        return os.path.abspath(p)
    slug = p.rstrip("/")
    top = os.path.join(plans_root, slug)
    if os.path.isfile(os.path.join(top, "manifest.json")):
        return top
    subs = sorted(d for d in glob.glob(os.path.join(plans_root, "*", slug))
                  if os.path.isfile(os.path.join(d, "manifest.json")))
    if subs:
        return subs[0]
    miss("plan '%s' not found (as a dir, or under %s)" % (p, plans_root))


plan_dir = resolve_plan(plan_arg)
slug = os.path.basename(plan_dir)
try:
    man = json.loads(read(os.path.join(plan_dir, "manifest.json")))
except Exception:
    miss("%s/manifest.json does not parse" % plan_dir)
if not isinstance(man, dict):
    miss("%s/manifest.json is not an object" % plan_dir)


# --- markdown sections ------------------------------------------------------------------
def headings(lines):
    """[(index, level, text)] for every ATX heading outside fenced code."""
    out, fenced = [], False
    for i, l in enumerate(lines):
        if FENCE.match(l):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = MD_HEAD.match(l)
        if m:
            out.append((i, len(m.group(1)), m.group(2).strip()))
    return out


def section(rel, want):
    path = os.path.normpath(os.path.join(plan_dir, rel))
    if not os.path.isfile(path):
        miss("file '%s' not found in %s" % (rel, plan_dir))
    lines = read(path).splitlines()
    hs = headings(lines)
    w = want.strip().lower()
    hit = [h for h in hs if h[2].lower() == w]
    if not hit:
        hit = [h for h in hs if re.match(re.escape(w) + r"(?![\w-])", h[2].lower())]
    if not hit:
        miss("heading '%s' not found in %s" % (want, rel))
    i, lvl, _ = hit[0]
    end = len(lines)
    for j, l2, _t in hs:
        if j > i and l2 <= lvl:
            end = j
            break
    return "\n".join(lines[i:end]).rstrip() + "\n"


def adr_text(adr_id):
    for rec in (man.get("decision_records") or []):
        if isinstance(rec, dict) and rec.get("id") == adr_id and rec.get("path"):
            p = os.path.normpath(os.path.join(plan_dir, str(rec["path"])))
            if os.path.isfile(p):
                return read(p)
    hits = sorted(glob.glob(os.path.join(plan_dir, "decisions", adr_id + "-*.md")))
    if not hits:
        miss("decision '%s' not found in %s" % (adr_id, plan_dir))
    return read(hits[0])


# --- the handoff ------------------------------------------------------------------------
def handoff_entries():
    """Newest-first [(heading, date, text)]. The ledger picks and orders the entries when it
    holds rows for this plan; the text is always sliced from handoff.md."""
    hp = os.path.join(plan_dir, "handoff.md")
    if not os.path.isfile(hp):
        miss("no handoff.md in %s" % plan_dir)
    lines = read(hp).splitlines()
    starts = [i for i, l in enumerate(lines)
              if (lambda m: m is not None and m.group(1) == "##")(HEADING_RE.match(l))]
    blocks = {}
    order = []
    for k, i in enumerate(starts):
        end = len(lines)
        for j in range(i + 1, len(lines)):
            if re.match(r"^##(?!#)\s", lines[j]):
                end = j
                break
        head = lines[i].lstrip("#").strip()
        dm = DATE_RE.search(head)
        blocks[head] = (head, dm.group(1) if dm else None, "\n".join(lines[i:end]).rstrip() + "\n")
        order.append(head)
    spoke = str(man.get("project") or "").strip()
    ledger = os.path.join(plans_root, "_projects", spoke, "handoff-ledger.jsonl") if spoke else ""
    rows = []
    if ledger and os.path.isfile(ledger):
        for raw in read(ledger).splitlines():
            try:
                r = json.loads(raw)
            except Exception:
                continue
            if isinstance(r, dict) and r.get("plan") == slug and r.get("heading"):
                rows.append(r)
    if rows:
        # Newest first by the chronicle's own key (plan-handoff-index render_key): the
        # heading's session ordinal, then its date, then the row's document position.
        def key(r):
            sn = NUM_RE.search(r["heading"])
            sd = DATE_RE.search(r["heading"])
            return (int(sn.group(1)) if sn else -1, sd.group(1) if sd else "",
                    r.get("pos") if isinstance(r.get("pos"), int) else 0)
        out = []
        for r in sorted(rows, key=key, reverse=True):
            b = blocks.get(r["heading"])
            if b:
                out.append((b[0], r.get("date") or b[1], b[2]))
            else:
                out.append((r["heading"], r.get("date"),
                            "## %s\n\n%s\n%s\n" % (r["heading"], r.get("summary") or "", r.get("next") or "")))
        return out
    return [blocks[h] for h in order]


# --- the canonical set and the decisions ------------------------------------------------
def canon():
    out = []
    for ra in (man.get("research_artifacts") or []):
        if not isinstance(ra, dict):
            continue
        p = os.path.normpath(str(ra.get("path") or "."))
        st = str(ra.get("status") or "").strip().lower()
        if p.startswith("_research" + os.sep) and st not in ("superseded", "deferred"):
            out.append((p, str(ra.get("id") or ""), str(ra.get("title") or "")))
    return sorted(out)


def live_decisions():
    out = []
    for rec in (man.get("decision_records") or []):
        if isinstance(rec, dict) and str(rec.get("status") or "").lower() != "superseded":
            out.append(rec)
    return out


# --- selectors --------------------------------------------------------------------------
buf = []
narrow = "--task T-n or --section \"<heading>\""

if mode == "task":
    tasks = [t for t in (man.get("tasks") or []) if isinstance(t, dict) and t.get("id") == arg]
    if not tasks:
        miss("task '%s' not found in %s/manifest.json" % (arg, slug))
    t = tasks[0]
    buf.append("# %s: %s" % (t.get("id"), t.get("title") or ""))
    buf.append("status: %s" % (t.get("status") or "—"))
    buf.append("depends_on: %s" % (", ".join(map(str, t.get("depends_on") or [])) or "—"))
    buf.append("")
    buf.append("## Description")
    buf.append(str(t.get("description") or "—"))
    for label, key in (("Acceptance criteria", "acceptance_criteria"),
                       ("file_references", "file_references"), ("sot_refs", "sot_refs")):
        buf.append("")
        buf.append("## %s" % label)
        items = t.get(key) or []
        buf.extend("- %s" % x for x in items) if items else buf.append("—")
    refs = t.get("context_refs") or []
    if refs:
        buf.append("")
        buf.append("## context_refs")
        for ref in refs:
            ref = str(ref)
            buf.append("")
            buf.append("### %s" % ref)
            if re.match(r"^ADR-[0-9]{2,}$", ref):
                buf.append(adr_text(ref).rstrip())
            elif "#" in ref:
                f, h = ref.split("#", 1)
                buf.append(section(f, h).rstrip())
            else:
                p = os.path.normpath(os.path.join(plan_dir, ref))
                if not os.path.isfile(p):
                    miss("file '%s' not found in %s" % (ref, plan_dir))
                buf.append(read(p).rstrip())
    narrow = "--section \"<heading>\" for one context_ref"

elif mode == "section":
    if not arg.strip():
        sys.stderr.write("plan-context: --section needs a heading\n")
        sys.exit(2)
    text = section(file_rel, arg)
    buf.append(text.rstrip())
    subs = [h[2] for h in headings(text.splitlines())[1:]]
    narrow = ("--section \"%s\" --file %s" % (subs[0], file_rel)) if subs else \
             "a sub-heading of this section with --section"

elif mode == "canon":
    rows = canon()
    buf.append("# %s: canonical research (%d)" % (slug, len(rows)))
    buf.extend("- %s (%s): %s" % (p, i or "—", t or "—") for p, i, t in rows)
    narrow = "--section \"<heading>\" --file <one canonical path>"

elif mode == "decisions":
    recs = live_decisions()
    buf.append("# %s: decisions not superseded (%d)" % (slug, len(recs)))
    buf.extend("- %s: %s (%s) — %s" % (r.get("id"), r.get("title") or "—", r.get("status") or "—",
                                        r.get("path") or "—") for r in recs)
    narrow = "--task T-n with context_refs naming one ADR"

elif mode == "handoff":
    entries = handoff_entries()
    if since:
        if not re.match(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", since):
            sys.stderr.write("plan-context: --since needs YYYY-MM-DD\n")
            sys.exit(2)
        entries = [e for e in entries if e[1] and e[1] >= since]
    elif arg == "latest":
        entries = entries[:1]
    elif re.match(r"^[0-9]+$", arg):
        entries = entries[:int(arg)]
    else:
        sys.stderr.write("plan-context: --handoff takes latest, <N> or --since <YYYY-MM-DD>\n")
        sys.exit(2)
    if not entries:
        miss("no handoff entry matches in %s/handoff.md" % slug)
    buf.append("\n".join(e[2].rstrip() + "\n" for e in entries).rstrip())
    narrow = "--handoff latest"

else:  # the plan map
    rows = canon()
    buf.append("# plan-context: %s" % slug)
    buf.append("Canonical research (%d): %s" % (len(rows), ", ".join(p for p, _i, _t in rows) or "—"))
    hp = os.path.join(plan_dir, "handoff.md")
    htext = read(hp) if os.path.isfile(hp) else ""
    buf.append("Rulings: %d `- <FORK>: ruled` line(s) in handoff.md"
               % sum(1 for l in htext.splitlines() if RULED_RE.match(l)))
    gd = os.path.join(plan_dir, "_gates")
    ngates = sum(1 for f in os.listdir(gd) if not f.startswith(".") and os.path.isfile(os.path.join(gd, f))) \
        if os.path.isdir(gd) else 0
    buf.append("Gates: %d file(s) in _gates/" % ngates)
    assets = [a for a in (man.get("assets") or []) if isinstance(a, dict) and a.get("path")]
    try:
        mset = json.loads(mset_s)
    except Exception:
        mset = None
    if isinstance(mset, list):
        managed = set(str(x).rstrip("/") for x in mset)
        excused = set(str(a["path"]).strip("/").split("/")[0] for a in assets)
        ap = str(man.get("architecture_path") or "").strip()
        if ap:
            apn = os.path.normpath(os.path.join(plan_dir, ap)) if not os.path.isabs(ap) else os.path.normpath(ap)
            rel = os.path.relpath(apn, plan_dir)
            if not rel.startswith(".."):
                excused.add(rel.split(os.sep)[0])
        unmanaged = []
        for e in sorted(os.listdir(plan_dir)):
            if e.startswith(".") or e in managed or e in excused:
                continue
            if os.path.isfile(os.path.join(plan_dir, e, "manifest.json")):
                continue
            unmanaged.append(e)
        um = ", ".join(unmanaged) or "none"
    else:
        um = "unknown (plan_folder_managed_set unreadable)"
    buf.append("Assets: %d row(s)%s; unmanaged entries: %s"
               % (len(assets), (" (" + ", ".join(str(a["path"]) for a in assets) + ")") if assets else "", um))
    buf.append("capability_touch: %s" % ("present" if "capability_touch" in man else "absent"))
    newest = None
    if htext:
        hl = htext.splitlines()
        for i, l in enumerate(hl):
            m = HEADING_RE.match(l)
            if m and m.group(1) == "##":
                nxt = "—"
                for l2 in hl[i + 1:]:
                    if re.match(r"^##(?!#)\s", l2):
                        break
                    if NEXT_RE.match(l2):
                        nxt = l2.strip()
                        break
                newest = "%s — Next: %s" % (l.lstrip("#").strip(), nxt)
                break
    buf.append("Newest entry: %s" % (newest or "—"))
    narrow = "--task T-n"

out = "\n".join(buf).rstrip() + "\n"
if len(out) > LIMIT:
    tail = "\n[plan-context: cut at %d characters; narrow it with %s]\n" % (LIMIT, narrow)
    out = out[:LIMIT - len(tail)].rstrip() + tail
sys.stdout.write(out)
PY
