#!/usr/bin/env bash
# hygiene-audit.sh - the backlog hygiene audit as one command: it reads the flat idea notes and
# the top-level plan manifests, applies the funnel and lifecycle timeouts and the disposition and
# integrity checks, writes the hygiene report and prints the summary block.
#
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/backlog-hygiene/scripts/hygiene-audit.sh [--dry-run] [--fix] [--plans-root DIR]
#
# INPUTS: the idea notes `_inbox/*.md` whose name does not start with `_`, and the manifests
# `<root>/*/manifest.json`; days stale is today minus the first ten characters of `updated`
# (an absent or unparseable value is one Info row, `age unknown`, and skips that item's age checks).
# Staleness timeouts and the trigger and recommended-action text of each row are embedded in
# this script (it reads no skill text at run time); the disposition tiers, the enums, the slug
# patterns and the terminal statuses come from the plans rules.
#
# OUTPUT: unless --dry-run, $HOOKS_STATE/backlog-hygiene-report.md is written atomically, always,
# even when nothing is flagged: a temp file `.backlog-hygiene-report.md.tmp.<pid>` in the same
# directory and a PATH-resolved plain `mv`. The summary block goes to stdout.
#
# --dry-run writes no file at all (no report, no state directory, no flag) and suppresses --fix.
# --fix appends one dated line to the `## Notes` section of each idea note whose missing
# disposition is at or past the second stale_advisory_days tier, once per note, frontmatter
# untouched; a manifest is never written. Each flag is its own temp-file rename: a failed write
# leaves that note untouched, is reported in its row, and the run goes on to the next note.
#
# EXIT CODES: 0 done; 2 refused; 1 the report could not be written.
#
# RULES come from the plans-rules chain: PLANS_RULES_PATH, then
# ${CLAUDE_HOME:-$HOME/.claude}/governance/plans-rules.json, then
# foundation-overlay-load.sh --query '.plans' --force-override. The plans root is --plans-root,
# else PLANS_ROOT, else PLANS_DIR as hooks/lib/paths.sh resolves it, else $HOME/.claude-plans;
# the resolved root is exported as both PLANS_ROOT and PLANS_DIR before any child runs.
#
# DERIVATIONS a tool-event write of a note would have fired, run here because a script write
# fires none: after each flag is written the PostToolUse hook post-tool-use-manifest.sh runs once
# with the Write payload for that note, and its inbox prompt is relayed as one `NOTE:` line on
# stderr; a missing hook prints a `NOTE:` and the run goes on. This command never regenerates the
# backlog view and never writes it: the report names /librarian backlog-index as the next step.
#
# Bash 3.2 clean. Data reaches python through argv, never a piped stdin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../hooks/lib/paths.sh" 2>/dev/null || true
set -u

ROOT=""

usage() {
  printf 'usage: hygiene-audit [--dry-run] [--fix] [--plans-root DIR]\n'
  printf 'exit: 0 done; 2 refused; 1 the report could not be written\n'
  printf 'run /librarian backlog-index afterwards when the report recommends it\n'
}

finish() {
  local rc=$? f
  trap - EXIT INT TERM HUP
  if [ -n "$ROOT" ]; then
    for f in "$ROOT"/_inbox/.*.md.tmp."$$"; do
      if [ -e "$f" ]; then rm -f -- "$f"; fi
    done
  fi
  if [ -n "${HOOKS_STATE:-}" ] && [ -e "$HOOKS_STATE/.backlog-hygiene-report.md.tmp.$$" ]; then
    rm -f -- "$HOOKS_STATE/.backlog-hygiene-report.md.tmp.$$"
  fi
  exit "$rc"
}
trap finish EXIT INT TERM HUP

refuse() {
  printf 'hygiene-audit: refused: %s\n' "$1" >&2
  exit 2
}

DRY=0; FIX=0; ROOT_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY=1; shift ;;
    --fix) FIX=1; shift ;;
    --plans-root)
      [ $# -ge 2 ] || refuse "--plans-root needs a non-empty value"
      [ -n "$2" ] || refuse "--plans-root needs a non-empty value"
      ROOT_FLAG="$2"; shift 2 ;;
    -*) refuse "unknown flag '$1'" ;;
    *) refuse "unexpected argument '$1'" ;;
  esac
done
command -v python3 >/dev/null 2>&1 || refuse "python3 is required"

if [ "$DRY" = 1 ] && [ "$FIX" = 1 ]; then
  printf 'NOTE: --fix suppressed by --dry-run\n' >&2
  FIX=0
fi

TODAY="${SESSION_CLOSE_TODAY:-$(date '+%Y-%m-%d')}"

ROOT="${ROOT_FLAG:-${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}}"
case "$ROOT" in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac
while [ "${ROOT%/}" != "$ROOT" ]; do ROOT="${ROOT%/}"; done
export PLANS_ROOT="$ROOT" PLANS_DIR="$ROOT"

RULES_JSON=""
load_rules() {
  local ch="${CLAUDE_HOME:-$HOME/.claude}" cand loader out
  for cand in "${PLANS_RULES_PATH:-}" "$ch/governance/plans-rules.json"; do
    if [ -n "$cand" ] && [ -f "$cand" ]; then RULES_JSON="$(cat "$cand")"; return 0; fi
  done
  loader="$ch/hooks/lib/foundation-overlay-load.sh"
  if [ -x "$loader" ]; then
    out="$(bash "$loader" --query '.plans' --force-override 2>/dev/null)"
    if [ -n "$out" ] && [ "$out" != "null" ]; then RULES_JSON="$out"; return 0; fi
  fi
  return 1
}
load_rules || refuse "no plans rules found"

if [ "$DRY" = 0 ] && [ -z "${HOOKS_STATE:-}" ]; then
  refuse "HOOKS_STATE is unresolved (paths.sh is missing beside this script)"
fi

IFS= read -r -d '' PY_AUDIT <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import date

try:
    sys.stdout.reconfigure(errors="surrogateescape")
    sys.stderr.reconfigure(errors="surrogateescape")
except AttributeError:
    pass

root, today_s, rules_text, state_dir, pid, claude_home, dry_s, fix_s = sys.argv[1:9]
dry_run = dry_s == "1"
fix = fix_s == "1"
KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")
PLACEHOLDER = "{One paragraph: what's the idea?}"
SEV_RANK = {"Error": 0, "Alert": 1, "Warning": 2, "Info": 3}
MID = "·"
DASH = "—"


def refuse(reason):
    sys.stderr.write("hygiene-audit: refused: %s\n" % reason)
    sys.exit(2)


try:
    today = date.fromisoformat(today_s)
except ValueError:
    refuse("today '%s' is not a YYYY-MM-DD date" % today_s)
try:
    rules = json.loads(rules_text)
    disp_enum = list(rules["backlog_row"]["disposition_enum"])
    adv = list(rules["backlog_row"]["stale_advisory_days"])
    status_enum = list(rules["lifecycle"]["status_enum"])
    terminal = list(rules["lifecycle"]["terminal_status"])
    plan_pattern = rules["slug_rules"]["pattern"]
    note_pattern = rules["inbox"]["slug_pattern"]
    adv_warn, adv_alert = adv[0], adv[1]
except (ValueError, KeyError, TypeError, IndexError):
    refuse("no plans rules found")

# the funnel and lifecycle timeouts: (status, days, severity, trigger, recommended action)
NOTE_TIMEOUTS = (
    ("new", 7, "Warning", "Captured but not triaged",
     "Run `/backlog-triage --item <slug>`, or remove the note"),
    ("triaged", 7, "Warning", "Triaged but not researched/graduated",
     "Run `/backlog-research --promote <slug>` or `/backlog-research <slug>`, or defer with reason"),
    ("briefed", 14, "Warning", "Brief exists but never graduated to a plan",
     "Review the note and decide: promote to a plan, defer, or remove"),
)
PLAN_TIMEOUTS = (
    ("researching", 3, "Alert", "No research output produced",
     "Check whether the research session failed; restart or defer"),
    ("planned", 14, "Warning", "Planned but not started",
     "Confirm still intended; start, defer, or close"),
    ("in-progress", 7, "Alert", "No file changes in the plan dir",
     "Check whether blocked; update `manifest.updated`, or close"),
)
I_MISSING = "Missing disposition (R-56)"
I_ORPHAN = "Manifest status orphan"
I_SLUG = "Slug violation"
I_BRIEF = "Missing brief"
I_STUCK = "Stuck dependency"
I_HOLLOW = "Hollow idea note (`inbox-hollow-idea`)"
REFRESH_ACTION = "Update `manifest.updated`; the plan directory shows recent git activity"
UNKNOWN_ACTION = "Set `updated` in the frontmatter so the age checks can run"


def bkey(name):
    return name.encode("utf-8", "surrogateescape")


def unq(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def read(path):
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        return fh.read()


def days_since(value):
    try:
        return (today - date.fromisoformat(str(value).strip()[:10])).days
    except (TypeError, ValueError):
        return None


def note_parts(text):
    """(frontmatter dict, head text through the closing fence, body text)."""
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end >= 0:
            fm = {}
            for ln in text[4:end].split("\n"):
                m = KEY_RE.match(ln)
                if m and m.group(1) not in fm:
                    fm[m.group(1)] = unq(m.group(2))
            return fm, text[:end + 5], text[end + 5:]
    return {}, "", text


def section(blines, heading):
    """(index of the heading line, index after the section) or (-1, -1)."""
    for i, ln in enumerate(blines):
        if ln.rstrip() == heading:
            for j in range(i + 1, len(blines)):
                if blines[j].startswith("## "):
                    return i, j
            return i, len(blines)
    return -1, -1


# --- load ---------------------------------------------------------------------------
inbox_dir = os.path.join(root, "_inbox")
notes = []
if os.path.isdir(inbox_dir):
    names = [n for n in os.listdir(inbox_dir)
             if n.endswith(".md") and not n.startswith(("_", ".")) and os.path.isfile(os.path.join(inbox_dir, n))]
    for n in sorted(names, key=bkey):
        path = os.path.join(inbox_dir, n)
        try:
            text = read(path)
        except OSError:
            text = ""
        fm, head, body = note_parts(text)
        notes.append({"slug": n[:-3], "name": n, "path": path, "fm": fm, "body": body,
                      "days": days_since(fm.get("updated", ""))})
plans = []
if os.path.isdir(root):
    for d in sorted(os.listdir(root), key=bkey):
        if d.startswith(("_", ".")):
            continue
        mp = os.path.join(root, d, "manifest.json")
        if not (os.path.isdir(os.path.join(root, d)) and os.path.isfile(mp)):
            continue
        try:
            with open(mp, encoding="utf-8", errors="surrogateescape") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        plans.append({"dir": d, "path": mp, "data": data,
                      "status": data.get("status"), "days": days_since(data.get("updated", ""))})
plan_status = {p["dir"]: p["status"] for p in plans}


def plan_dir_status(entry):
    key = unq(str(entry)).split("::")[0].strip()
    if not key or key.startswith("/") or ".." in key.split("/"):
        return None
    if key in plan_status:
        return plan_status[key]
    mp = os.path.join(root, key, "manifest.json")
    if os.path.isfile(mp):
        try:
            with open(mp, encoding="utf-8", errors="surrogateescape") as fh:
                return json.load(fh).get("status")
        except (OSError, ValueError, AttributeError):
            return None
    return None


def git_recent(dirname):
    """The committer date (YYYY-MM-DD) of the newest commit touching the plan directory, or None."""
    env = dict(os.environ)
    for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        env.pop(k, None)
    try:
        inside = subprocess.run(["git", "-C", root, "rev-parse", "--is-inside-work-tree"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=env, timeout=30)
        if inside.returncode != 0 or inside.stdout.decode().strip() != "true":
            return None
        out = subprocess.run(["git", "-C", root, "log", "-1", "--format=%cs", "--", dirname],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, env=env, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.decode().strip() or None


rows_f = []
rows_d = []


def add_f(item, source, status, days, sev, issue, action):
    rows_f.append({"item": item, "source": source, "status": status, "days": days,
                   "sev": sev, "issue": issue, "action": action})


def add_d(item, issue, sev, detail, days=None, note=None):
    row = {"item": item, "issue": issue, "sev": sev, "detail": detail, "days": days, "note": note}
    rows_d.append(row)
    return row


# --- staleness (the funnel and lifecycle timeouts) ------------------------------------
for n in notes:
    st = n["fm"].get("status", "")
    if n["days"] is None:
        add_f(n["slug"], "inbox", st or "-", None, "Info", "age unknown", UNKNOWN_ACTION)
        continue
    for name, timeout, sev, trigger, action in NOTE_TIMEOUTS:
        if st == name and n["days"] >= timeout:
            add_f(n["slug"], "inbox", st, n["days"], sev, trigger, action)
for p in plans:
    st = p["status"]
    for name, timeout, sev, trigger, action in PLAN_TIMEOUTS:
        if st != name:
            continue
        if p["days"] is None:
            add_f(p["dir"], "plan", st, None, "Info", "age unknown", UNKNOWN_ACTION)
        elif p["days"] >= timeout:
            recent = git_recent(p["dir"]) if st == "in-progress" else None
            gap = days_since(recent) if recent else None
            if gap is not None and gap <= 7:
                add_f(p["dir"], "plan", st, p["days"], "Info", "needs manifest.updated refresh", REFRESH_ACTION)
            else:
                add_f(p["dir"], "plan", st, p["days"], sev, trigger, action)

# --- disposition and lifecycle integrity -----------------------------------------------
missing_notes = []
for n in notes:
    fm = n["fm"]
    disp = fm.get("disposition", "")
    if (not disp or disp not in disp_enum) and n["days"] is not None and n["days"] >= adv_warn:
        sev = "Alert" if n["days"] >= adv_alert else "Warning"
        what = "no disposition" if not disp else "disposition '%s' is not in backlog_row.disposition_enum" % disp
        row = add_d(n["slug"], I_MISSING, sev, "%s after %d days" % (what, n["days"]), n["days"], n)
        if n["days"] >= adv_alert:
            missing_notes.append((n, row))
    if not re.fullmatch(note_pattern, n["slug"]):
        add_d(n["slug"], I_SLUG, "Warning", "note '%s' does not match inbox.slug_pattern" % n["slug"], n["days"])
    if fm.get("status", "") == "briefed":
        target = unq(fm.get("promoted_to", "")).split("::")[0].strip()
        ok = bool(target) and not target.startswith("/") and ".." not in target.split("/") \
            and os.path.isfile(os.path.join(root, target, "00-ideation-brief.md"))
        if not ok:
            detail = "promoted_to '%s' does not hold 00-ideation-brief.md" % target if target else "no promoted_to"
            add_d(n["slug"], I_BRIEF, "Warning", detail, n["days"])
    blines = n["body"].split("\n")
    h, stop = section(blines, "## Idea")
    if h >= 0 and any(PLACEHOLDER in ln for ln in blines[h + 1:stop]):
        add_d(n["slug"], I_HOLLOW, "Warning", "the Idea section still holds the capture placeholder", n["days"])
for p in plans:
    data = p["data"]
    st = p["status"]
    if not isinstance(st, str) or st not in status_enum:
        add_d(p["dir"], I_ORPHAN, "Error",
              "status '%s' is not in lifecycle.status_enum" % st if isinstance(st, str) else "no status", p["days"])
    if not re.fullmatch(plan_pattern, p["dir"]):
        add_d(p["dir"], I_SLUG, "Warning", "directory '%s' does not match slug_rules.pattern" % p["dir"], p["days"])
    if st in ("researching", "planned"):
        disp = data.get("disposition", "")
        disp = disp if isinstance(disp, str) else ""
        if (not disp or disp not in disp_enum) and p["days"] is not None and p["days"] >= adv_warn:
            sev = "Alert" if p["days"] >= adv_alert else "Warning"
            what = "no disposition" if not disp else "disposition '%s' is not in backlog_row.disposition_enum" % disp
            add_d(p["dir"], I_MISSING, sev, "%s after %d days" % (what, p["days"]), p["days"])
    if st == "researching" and not os.path.isfile(os.path.join(root, p["dir"], "00-ideation-brief.md")):
        add_d(p["dir"], I_BRIEF, "Warning", "no 00-ideation-brief.md", p["days"])
    if st == "paused" and data.get("paused_reason") == "blocked-on-dependency":
        deps = data.get("dependencies")
        prereq = deps.get("hard_prereq_other_plans") if isinstance(deps, dict) else None
        if isinstance(prereq, list) and prereq and all(plan_dir_status(e) in terminal for e in prereq):
            add_d(p["dir"], I_STUCK, "Warning",
                  "every hard prerequisite is terminal: %s" % ", ".join(str(e) for e in prereq), p["days"])


# --- --fix: one flag line per aged note, one temp-file rename each ----------------------
def run_hook(path):
    hook = os.path.join(claude_home, "hooks", "post-tool-use-manifest.sh")
    if not os.path.isfile(hook):
        sys.stderr.write("NOTE: inbox-triage prompt skipped (%s is missing)\n" % hook)
        return
    payload = json.dumps({"tool_name": "Write", "tool_input": {"file_path": path}})
    try:
        res = subprocess.run(["bash", hook], input=payload.encode("utf-8"), stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=30)
        ctx = json.loads(res.stdout.decode("utf-8", "replace")).get("hookSpecificOutput", {}).get("additionalContext", "")
    except subprocess.TimeoutExpired:
        sys.stderr.write("NOTE: inbox-triage prompt skipped (the hook did not finish in time)\n")
        return
    except (OSError, ValueError, AttributeError):
        return
    ctx = " ".join(str(ctx).split())
    if ctx:
        sys.stderr.write("NOTE: %s\n" % ctx)


def enum_phrase(vals):
    vals = [str(v) for v in vals]
    if len(vals) <= 1:
        return "".join(vals)
    return ", ".join(vals[:-1]) + " or " + vals[-1]


applied = []
if fix and not dry_run:
    for n, row in missing_notes:
        try:
            text = read(n["path"])
        except OSError:
            row["detail"] = "flag not appended: write failed"
            continue
        _fm, head, body = note_parts(text)
        blines = body.split("\n")
        h, stop = section(blines, "## Notes")
        if h < 0:
            row["detail"] = "flag not appended: no '## Notes' section"
            continue
        if any("[backlog-hygiene " in ln for ln in blines[h + 1:stop]):
            continue
        last = h
        for i in range(h + 1, stop):
            if blines[i].strip():
                last = i
        blines.insert(last + 1, "- [backlog-hygiene %s] No disposition after %d days; decide %s."
                      % (today_s, n["days"], enum_phrase(disp_enum)))
        new_body = "\n".join(blines)
        if not new_body.endswith("\n"):
            new_body += "\n"
        tmp = os.path.join(inbox_dir, ".%s.tmp.%s" % (n["name"], pid))
        done = False
        try:
            with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
                fh.write(head + new_body)
            try:
                shutil.copymode(n["path"], tmp)
            except OSError:
                pass
            moved = subprocess.run(["mv", tmp, n["path"]], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            done = moved.returncode == 0
        except OSError:
            done = False
        if not done:
            if os.path.exists(tmp):
                os.unlink(tmp)
            row["detail"] = "flag not appended: write failed"
            continue
        applied.append((n, n["days"]))
        run_hook(n["path"])

# --- the next step, the rows in order, the report --------------------------------------
backlog = os.path.join(root, "_backlog.md")
regen = len(applied) > 0
if not regen:
    if not os.path.exists(backlog):
        regen = True
    else:
        mark = os.stat(backlog).st_mtime
        for path in [n["path"] for n in notes] + [p["path"] for p in plans]:
            if os.stat(path).st_mtime > mark:
                regen = True
                break


def order(row):
    days = row["days"] if row["days"] is not None else -1
    return (SEV_RANK[row["sev"]], -days, row["item"].encode("utf-8", "surrogateescape"))


rows_f.sort(key=order)
rows_d.sort(key=order)
everything = sorted(rows_f + rows_d, key=order)
counts = {"Warning": 0, "Alert": 0, "Error": 0, "Info": 0}
for r in everything:
    counts[r["sev"]] += 1
issues = len(everything)


def cell(value):
    return str(value).replace("|", "\\|")


def table(header, body_rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join(["---"] * len(header)) + "|"]
    for r in body_rows:
        out.append("| " + " | ".join(cell(c) for c in r) + " |")
    return out


report = ["# Backlog Hygiene Report", "",
          "**Date:** %s" % today_s,
          "**Inbox notes scanned:** %d" % len(notes),
          "**Plan manifests scanned:** %d" % len(plans),
          "**Issues found:** %d" % issues,
          "**Auto-fixes applied:** %d" % len(applied), "",
          "## Flagged items", ""]
report += table(["Item", "Source", "Status", "Days stale", "Severity", "Issue", "Recommended action"],
                [[r["item"], r["source"], r["status"], "-" if r["days"] is None else r["days"],
                  r["sev"], r["issue"], r["action"]] for r in rows_f])
report += ["", "## Disposition + lifecycle issues (R-56 / R-29/30/31)", ""]
report += table(["Item", "Issue", "Severity", "Detail"],
                [[r["item"], r["issue"], r["sev"], r["detail"]] for r in rows_d])
report += ["", "## Auto-maintenance applied (--fix)", ""]
report += table(["Item", "Operation", "Detail"],
                [[n["slug"], "R-56 auto-flag missing disposition", "appended a flag line (%d days)" % d]
                 for n, d in applied])
report += ["", "## Recommended next steps", "",
           "- Regenerate the view: `/librarian backlog-index`" if regen else "- None.", "",
           "## Summary", "",
           "- Warnings: %d %s Alerts: %d %s Errors: %d %s Info: %d"
           % (counts["Warning"], MID, counts["Alert"], MID, counts["Error"], MID, counts["Info"]),
           "- All clear: %s" % ("Yes" if issues == 0 else "No"), ""]
report_path = os.path.join(state_dir, "backlog-hygiene-report.md") if state_dir else ""

if not dry_run:
    tmp = os.path.join(state_dir, ".backlog-hygiene-report.md.tmp.%s" % pid)
    ok = True
    try:
        os.makedirs(state_dir, exist_ok=True)
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
            fh.write("\n".join(report))
        ok = subprocess.run(["mv", tmp, report_path], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        ok = False
    if not ok:
        if os.path.exists(tmp):
            os.unlink(tmp)
        sys.stderr.write("hygiene-audit: could not write %s; nothing changed\n" % report_path)
        sys.exit(1)

print("## Backlog Hygiene Complete")
print("")
print("Inbox notes: %d %s Plan manifests: %d" % (len(notes), MID, len(plans)))
line = "Issues: %d (Warnings: %d %s Alerts: %d %s Errors: %d %s Info: %d)" % (
    issues, counts["Warning"], MID, counts["Alert"], MID, counts["Error"], MID, counts["Info"])
if fix:
    line += " %s Auto-fixes: %d" % (MID, len(applied))
print(line)
for i, r in enumerate(everything[:3], 1):
    print("  %d. %s: %s %s %s" % (i, r["sev"], r["item"], DASH, r["issue"]))
if regen and not dry_run:
    print("Recommended: `/librarian backlog-index`")
print("Full report: %s" % ("not written (--dry-run)" if dry_run else report_path))
PY

python3 -c "$PY_AUDIT" "$ROOT" "$TODAY" "$RULES_JSON" "${HOOKS_STATE:-}" "$$" "${CLAUDE_HOME:-$HOME/.claude}" "$DRY" "$FIX"
exit $?
