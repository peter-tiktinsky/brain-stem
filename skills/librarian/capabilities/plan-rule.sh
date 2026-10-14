#!/bin/bash
# plan-rule — records an operator ruling on an open fork, and routes a spec-changing ruling
# to a decision record.
#
# A ruling is the operator's answer to a fork a plan left open. It belongs in the session
# record that took it, not in the spec's prose. This verb writes it there:
#   1. The ruling line   - <FORK>: ruled <choice> — "<quote>"
#      goes under a `### Rulings` heading inside the newest handoff entry (created at the
#      end of that entry when absent). The newest entry is the first H2 session heading,
#      read with the shared recognizer hooks/lib/handoff-recognizer.sh
#      (HANDOFF_SESSION_HEADING_PY). No other entry changes.
#   2. With --spec-change (the ruling changes the spec's Goal, Constraints or Solution):
#      - mints <plan>/decisions/ADR-NN-<slug>.md. NN is the highest ordinal already in
#        decisions/ or in manifest.json :: decision_records[], plus one (two digits
#        minimum). The slug is the kebab-case --title. The name must match the plans
#        pillar's decision_records.filename_pattern. The body carries the H1
#        `# ADR-NN: <title>`, `**Status:** accepted` and the pillar's required_sections
#        (Context, Decision, Consequences) in order;
#      - appends {id, title, status: accepted, path} to manifest.json :: decision_records[];
#      - appends `- Amended by ADR-NN: <title>` under the spec's `## Amendment register`,
#        a heading created once at the end of spec.md.
#   The spec's head sections stay as written; the register is the one pointer list, and the
#   ADR carries the change.
#
# Output Contract:
#   Files written: <plan-dir>/handoff.md. With --spec-change also
#     <plan-dir>/decisions/ADR-NN-<slug>.md (new), <plan-dir>/manifest.json and
#     <plan-dir>/spec.md. Each write is atomic (temp file + os.replace in the same dir).
#   stdout: `plan-rule: <handoff path> Session <N> <FORK>`, plus
#     `plan-rule: minted <plan-dir>/decisions/ADR-NN-<slug>.md` with --spec-change.
#   Schema: governance/plans-rules.json :: decision_records (dir, filename_pattern,
#     required_sections), read from the .plans slot of the merged foundation + overlay
#     view, else the raw bundle, else the repo pillar. PLANS_RULES_PATH wins first.
#   Pre-write validation: handoff.md exists and holds at least one H2 session heading;
#     <fork>, <choice> and --quote are non-empty single lines. With --spec-change:
#     --title is a non-empty single line whose ADR filename matches the pattern, spec.md
#     and manifest.json exist, manifest.json parses as an object, and the ADR file does
#     not exist yet. Every check runs before the first write. Any miss exits 2 with a
#     stderr reason and writes nothing.
#   Failure mode: block-and-log (exit 2, no write). Never write-and-hope.
#
# CLI:
#   plan-rule.sh <plan-dir> <fork> <choice> --quote "<text>" [--spec-change --title "<t>"]
#   plan-rule.sh --help
#
# Env overrides (testing):
#   CLAUDE_HOME              where the recognizer lib and the composed master are read first
#   FOUNDATION_MASTER_PATH   the composed master to read the plans pillar from
#   PLANS_RULES_PATH         a plans pillar (raw or bundled) read before the master
#
# Bash 3.2 clean. Data reaches Python through argv and the environment, never a piped stdin.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/handoff-recognizer.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/handoff-recognizer.sh"; } \
  || { [ -r "$_REPO_LIB/handoff-recognizer.sh" ] && source "$_REPO_LIB/handoff-recognizer.sh"; } \
  || { echo "plan-rule: hooks/lib/handoff-recognizer.sh unreadable under $CLAUDE_HOME_RES and $_REPO_LIB" >&2; exit 2; }

POS=()
QUOTE=""
QUOTE_SET="false"
SPEC_CHANGE="false"
TITLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quote)       QUOTE="${2:-}"; QUOTE_SET="true"; shift 2 ;;
    --spec-change) SPEC_CHANGE="true"; shift ;;
    --title)       TITLE="${2:-}"; shift 2 ;;
    -h|--help)     awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*)            echo "plan-rule: unknown flag '$1'" >&2; exit 2 ;;
    *)             POS+=("$1"); shift ;;
  esac
done

USAGE='plan-rule: usage: plan-rule <plan-dir> <fork> <choice> --quote "<text>" [--spec-change --title "<t>"]'
[ "${#POS[@]}" -eq 3 ] || { echo "$USAGE" >&2; exit 2; }
[ "$QUOTE_SET" = "true" ] || { echo "plan-rule: --quote is required" >&2; exit 2; }
PLAN_DIR="${POS[0]%/}"
[ -f "$PLAN_DIR/handoff.md" ] || { echo "plan-rule: no handoff.md in $PLAN_DIR" >&2; exit 2; }

# The decision_records convention: PLANS_RULES_PATH, then the merged foundation + overlay view
# (hooks/lib/foundation-overlay-load.sh, the union-load primitive), then the raw bundle, then
# the repo pillar. An UNREADABLE source fails closed immediately (unconditionally); an ABSENT
# source falls through to the next leg, and DR staying empty everywhere is the unconfigured
# convention (allow, unless --spec-change, which keeps its own fail-closed on absent below).
DR=""
if [ -n "${PLANS_RULES_PATH:-}" ] && [ -f "$PLANS_RULES_PATH" ]; then
  DR=$(bash "$CLAUDE_HOME_RES/hooks/lib/governance-read.sh" "$PLANS_RULES_PATH" '(.plans.decision_records // .decision_records) // empty')
  DR_LEG_RC=$?
  if [ "$DR_LEG_RC" -eq 3 ]; then
    echo "plan-rule: $PLANS_RULES_PATH: decision_records unreadable" >&2
    exit 2
  fi
fi
MASTER="${FOUNDATION_MASTER_PATH:-$CLAUDE_HOME_RES/governance/foundation-master.json}"
if [ -z "$DR" ] && [ -f "$MASTER" ]; then
  _OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
  [ -x "$_OVL" ] || _OVL="$_REPO_LIB/foundation-overlay-load.sh"
  if [ -x "$_OVL" ]; then
    DR_OVL_OUT=$(mktemp -t plan-rule-ovl-XXXXXX)
    bash "$_OVL" --foundation-path "$MASTER" \
        --overlay-path "$(dirname "$MASTER")/overlay-master.json" --force-override \
        >"$DR_OVL_OUT" 2>/dev/null
    DR_OVL_RC=$?
    if [ "$DR_OVL_RC" -ne 0 ]; then
      rm -f "$DR_OVL_OUT"
      echo "plan-rule: $MASTER: decision_records unreadable" >&2
      exit 2
    fi
    DR=$(bash "$CLAUDE_HOME_RES/hooks/lib/governance-read.sh" "$DR_OVL_OUT" '.plans.decision_records // empty')
    DR_LEG_RC=$?
    rm -f "$DR_OVL_OUT"
    if [ "$DR_LEG_RC" -eq 3 ]; then
      echo "plan-rule: $MASTER: decision_records unreadable" >&2
      exit 2
    fi
  fi
  if [ -z "$DR" ]; then
    DR=$(bash "$CLAUDE_HOME_RES/hooks/lib/governance-read.sh" "$MASTER" '.plans.decision_records // empty')
    DR_LEG_RC=$?
    if [ "$DR_LEG_RC" -eq 3 ]; then
      echo "plan-rule: $MASTER: decision_records unreadable" >&2
      exit 2
    fi
  fi
fi
if [ -z "$DR" ] && [ -f "$_REPO_ROOT/governance/plans-rules.json" ]; then
  DR=$(bash "$CLAUDE_HOME_RES/hooks/lib/governance-read.sh" "$_REPO_ROOT/governance/plans-rules.json" '.decision_records // empty')
  DR_LEG_RC=$?
  if [ "$DR_LEG_RC" -eq 3 ]; then
    echo "plan-rule: $_REPO_ROOT/governance/plans-rules.json: decision_records unreadable" >&2
    exit 2
  fi
fi
if [ "$SPEC_CHANGE" = "true" ] && [ -z "$DR" ]; then
  echo "plan-rule: plans pillar decision_records unreadable (master $MASTER, repo $_REPO_ROOT)" >&2
  exit 2
fi

python3 - "$PLAN_DIR" "${POS[1]}" "${POS[2]}" "$QUOTE" "$SPEC_CHANGE" "$TITLE" "$DR" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plan_dir, fork, choice, quote, spec_change, title, dr_s = sys.argv[1:8]
spec_change = spec_change == "true"


def refuse(msg):
    sys.stderr.write("plan-rule: %s\n" % msg)
    sys.exit(2)


def one_line(name, value):
    value = value.strip()
    if not value or "\n" in value or "\r" in value:
        refuse("%s must be one non-empty line" % name)
    return value


fork = one_line("<fork>", fork)
choice = one_line("<choice>", choice)
quote = one_line("--quote", quote)

HEADING_RE = re.compile(os.environ["HANDOFF_SESSION_HEADING_PY"], re.IGNORECASE)
NUM_RE = re.compile(os.environ["HANDOFF_SESSION_NUM_PY"], re.IGNORECASE)
H2_RE = re.compile(r"^##(?!#)\s")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def ensure_nl(lines):
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    return lines


def append_to_section(lines, head_idx, end, item):
    # Append `item` after the section's last non-blank line; the blank run before the next
    # heading is kept (one blank line at least when a heading follows).
    region = lines[head_idx + 1:end]
    t = 0
    while t < len(region) and not region[len(region) - 1 - t].strip():
        t += 1
    core = region[:len(region) - t] or ["\n"]
    ensure_nl(core)
    tail = region[len(region) - t:]
    if not tail and end < len(lines):
        tail = ["\n"]
    return lines[:head_idx + 1] + core + [item] + tail + lines[end:]


def add_under_heading(lines, lo, hi, heading_re, heading_line, stop_re, item):
    # Within lines[lo:hi]: append under the first heading matching heading_re, else open
    # heading_line at the end of the range (after its last non-blank line).
    for i in range(lo, hi):
        if heading_re.match(lines[i].rstrip("\r\n")):
            end = hi
            for j in range(i + 1, hi):
                if stop_re.match(lines[j]):
                    end = j
                    break
            return append_to_section(lines, i, end, item)
    k = hi
    while k > lo and not lines[k - 1].strip():
        k -= 1
    head = ensure_nl(lines[:k])
    tail = lines[k:hi]
    if not tail and hi < len(lines):
        tail = ["\n"]
    return head + ["\n", heading_line, "\n", item] + tail + lines[hi:]


def atomic_write(path, text, mode_from=None):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        if mode_from and os.path.exists(mode_from):
            os.chmod(tmp, os.stat(mode_from).st_mode & 0o7777)
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except Exception as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        refuse("write failed for %s: %s" % (path, exc))


# --- the handoff: newest entry = first H2 session heading -------------------------------
handoff = os.path.join(plan_dir, "handoff.md")
h_lines = read(handoff).splitlines(keepends=True)
start = None
for i, line in enumerate(h_lines):
    m = HEADING_RE.match(line.rstrip("\r\n"))
    if m and m.group(1) == "##":
        start = i
        break
if start is None:
    refuse("%s holds no H2 session heading; open one with handoff-entry first" % handoff)
entry_end = len(h_lines)
for j in range(start + 1, len(h_lines)):
    if H2_RE.match(h_lines[j]):
        entry_end = j
        break
heading_text = h_lines[start].rstrip("\r\n").lstrip("#").strip()
num = NUM_RE.search(heading_text)
session_label = "Session %s" % num.group(1) if num else heading_text

ruling = '- %s: ruled %s — "%s"\n' % (fork, choice, quote)
new_handoff = "".join(add_under_heading(
    h_lines, start + 1, entry_end, re.compile(r"^###\s+Rulings\s*$", re.IGNORECASE),
    "### Rulings\n", re.compile(r"^#{1,3}\s"), ruling))

writes = [(handoff, new_handoff)]
adr_rel = None

# --- the spec change: ADR + decision_records[] + amendment register ---------------------
if spec_change:
    title = one_line("--title", title)
    try:
        dr = json.loads(dr_s)
    except Exception:
        refuse("plans pillar decision_records is not JSON")
    pattern = dr.get("filename_pattern")
    sections = [str(s) for s in (dr.get("required_sections") or [])]
    sub = (dr.get("dir") or "decisions/").strip("/")
    if not pattern or not sections:
        refuse("plans pillar decision_records lacks filename_pattern or required_sections")
    spec = os.path.join(plan_dir, "spec.md")
    manifest_p = os.path.join(plan_dir, "manifest.json")
    if not os.path.isfile(spec):
        refuse("no spec.md in %s" % plan_dir)
    if not os.path.isfile(manifest_p):
        refuse("no manifest.json in %s" % plan_dir)
    try:
        manifest = json.loads(read(manifest_p))
    except Exception:
        refuse("%s does not parse as JSON" % manifest_p)
    if not isinstance(manifest, dict):
        refuse("%s is not a JSON object" % manifest_p)
    records = manifest.get("decision_records")
    if records is None:
        records = []
    if not isinstance(records, list):
        refuse("%s :: decision_records is not an array" % manifest_p)

    ddir = os.path.join(plan_dir, sub)
    top = 0
    if os.path.isdir(ddir):
        for name in os.listdir(ddir):
            m = re.match(r"^ADR-([0-9]+)-", name)
            if m:
                top = max(top, int(m.group(1)))
    for rec in records:
        m = re.match(r"^ADR-([0-9]+)$", str((rec or {}).get("id", "")) if isinstance(rec, dict) else "")
        if m:
            top = max(top, int(m.group(1)))
    adr_id = "ADR-%02d" % (top + 1)
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    fname = "%s-%s.md" % (adr_id, slug)
    if not re.match(pattern, fname):
        refuse("ADR filename %r does not match decision_records.filename_pattern %s" % (fname, pattern))
    adr_path = os.path.join(ddir, fname)
    if os.path.exists(adr_path):
        refuse("%s already exists" % adr_path)
    adr_rel = "%s/%s" % (sub, fname)

    today = date.today().isoformat()
    plan_base = os.path.basename(os.path.abspath(plan_dir))
    body = {
        "Context": 'The operator ruled %s in the handoff\'s %s: "%s". The ruling changes what '
                   "the spec states, so it is recorded here and the spec keeps its head sections "
                   "as written." % (fork, session_label, quote),
        "Decision": "We will take %s on %s: %s." % (choice, fork, title),
        "Consequences": "The spec's `## Amendment register` carries `Amended by %s: %s`, and "
                        "manifest.json :: decision_records[] carries this record. A later change "
                        "to this decision is a new ADR that supersedes this one; this file is not "
                        "edited in place." % (adr_id, title),
    }
    adr = ["---\n",
           "title: %s\n" % json.dumps("%s: %s" % (adr_id, title), ensure_ascii=False),
           "type: adr\n",
           "status: accepted\n",
           "parent_plan: %s\n" % plan_base,
           "created: %s\n" % today,
           "updated: %s\n" % today,
           "id: %s-%s\n" % (plan_base, fname[:-3].lower()),
           "schema_version: 1\n",
           "description: %s\n" % json.dumps("%s: %s (ruling %s)" % (adr_id, title, fork), ensure_ascii=False),
           "---\n\n",
           "# %s: %s\n\n" % (adr_id, title),
           "**Status:** accepted\n"]
    for s in sections:
        adr += ["\n## %s\n\n" % s, "%s\n" % body.get(s, "")]
    writes.append((adr_path, "".join(adr)))

    records = list(records) + [{"id": adr_id, "title": title, "status": "accepted", "path": adr_rel}]
    manifest["decision_records"] = records
    writes.append((manifest_p, json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"))

    s_lines = read(spec).splitlines(keepends=True)
    pointer = "- Amended by %s: %s\n" % (adr_id, title)
    new_spec = "".join(add_under_heading(
        s_lines, 0, len(s_lines), re.compile(r"^##\s+Amendment register\s*$", re.IGNORECASE),
        "## Amendment register\n", re.compile(r"^#{1,2}\s"), pointer))
    writes.append((spec, new_spec))

# --- every check has passed: write --------------------------------------------------------
for path, text in writes:
    if path.endswith(".md") and os.path.basename(path).startswith("ADR-"):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        atomic_write(path, text)
    else:
        atomic_write(path, text, mode_from=path)
print("plan-rule: %s %s %s" % (handoff, session_label, fork))
if adr_rel:
    print("plan-rule: minted %s" % os.path.join(plan_dir, adr_rel))
PY
