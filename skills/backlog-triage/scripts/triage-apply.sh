#!/usr/bin/env bash
# triage-apply.sh - classify one flat idea note in place: the status, disposition, related and
# updated keys, and one appended line in the note's `## Notes` section, in one atomic write.
#
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/backlog-triage/scripts/triage-apply.sh <slug>
#     --classification NOVEL|DUPLICATE|OVERLAP|DEFERRED --rationale <one line>
#     [--related a,b,c] [--reopen-gate <id>] [--plans-root DIR]
#
# WHAT EACH CLASSIFICATION WRITES (the triage skill's classification table):
#   NOVEL      status new -> triaged; no --related, no --reopen-gate
#   OVERLAP    status new -> triaged; --related with 1 to 3 slugs
#   DUPLICATE  status stays new;      --related with exactly 1 slug
#   DEFERRED   status stays new; disposition NO-BUILD (over an undecided or NO-BUILD note only);
#              --reopen-gate names a gate registered in the plans rules, not `_`-prefixed
# Triage is one-way: a note whose status is not `new` is refused. `updated` is set to today and
# `- [backlog-triage <today>] <CLASS>: <rationale>` is appended after the last non-blank line of
# the `## Notes` section, which is created when the note has none (the heading after the body's
# last non-blank line, one blank line between). Every other byte of the note is unchanged.
#
# EXIT CODES: 0 done; 2 refused with the note byte-identical; 1 the write failed (nothing changed).
# A refusal prints `triage-apply: refused: <reason>` on stderr. A refusal after the arguments
# parse (a note-class refusal or a failed write) also appends one `triage-aborted` JSON line to
# $HOOKS_STATE/backlog-triage-errors.jsonl; a usage-class refusal (an unknown flag, an empty value,
# a missing slug, classification or rationale) logs nothing.
#
# RULES come from the plans-rules chain: PLANS_RULES_PATH, then
# ${CLAUDE_HOME:-$HOME/.claude}/governance/plans-rules.json, then
# foundation-overlay-load.sh --query '.plans' --force-override. The plans root is --plans-root,
# else PLANS_ROOT, else PLANS_DIR as hooks/lib/paths.sh resolves it, else $HOME/.claude-plans;
# the resolved root is exported as both PLANS_ROOT and PLANS_DIR before any child runs.
#
# WRITE: the edited text goes to a temp file `.<slug>.md.tmp.<pid>` in the note's own directory
# (never ending .md, so no *.md glob reads it) and a PATH-resolved plain `mv` renames it over the
# note. A trap on EXIT, INT, TERM and HUP removes the temp file. No lock is taken.
#
# DERIVATIONS a tool-event write of the note would have fired, run here because a script write
# fires none: after a successful write the PostToolUse hook post-tool-use-manifest.sh runs once
# with the Write payload for the note, and its inbox prompt (an out-of-enum or empty disposition)
# is relayed as one `NOTE:` line on stderr. A missing hook prints a `NOTE:` and the command still
# succeeds. This command never runs backlog-index and never writes _backlog.md: the operator runs
# /librarian backlog-index to refresh the view.
#
# Bash 3.2 clean. Data reaches python through argv, never a piped stdin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$0"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../hooks/lib/paths.sh" 2>/dev/null || true
set -u

TMPF=""
SLUG=""

usage() {
  printf 'usage: triage-apply <slug> --classification NOVEL|DUPLICATE|OVERLAP|DEFERRED --rationale <one line> [--related a,b,c] [--reopen-gate <id>] [--plans-root DIR]\n'
  printf 'exit: 0 done; 2 refused (note unchanged); 1 the write failed (nothing changed)\n'
  printf 'run /librarian backlog-index afterwards to refresh _backlog.md\n'
}

finish() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [ -n "$TMPF" ]; then rm -f -- "$TMPF"; fi
  TMPF=""
  exit "$rc"
}
trap finish EXIT INT TERM HUP

# refuse_usage <reason>: a usage-class refusal; nothing is logged.
refuse_usage() {
  printf 'triage-apply: refused: %s\n' "$1" >&2
  exit 2
}

# log_abort <reason>: one triage-aborted line in the diagnostic file the skill names.
log_abort() {
  [ -n "${HOOKS_STATE:-}" ] || return 0
  # swallow-ok: reports=stderr the refusal or failure line is printed by the caller; the diagnostic log is best effort
  mkdir -p "$HOOKS_STATE" 2>/dev/null || return 0
  # swallow-ok: reports=stderr the refusal or failure line is printed by the caller; the diagnostic log is best effort
  jq -cn --arg s "$SLUG" --arg r "$1" --arg d "$TODAY" \
    '{finding: "triage-aborted", inbox_slug: $s, reason: $r, detected_at: $d}' \
    >> "$HOOKS_STATE/backlog-triage-errors.jsonl" 2>/dev/null || return 0
}

# refuse_note <reason>: a note-class refusal; logged, then the usage-style line and exit 2.
refuse_note() {
  log_abort "$1"
  printf 'triage-apply: refused: %s\n' "$1" >&2
  exit 2
}

CLASS=""; HAVE_CLASS=0; RATIONALE=""; HAVE_RAT=0; RELATED=""; GATE=""; ROOT_FLAG=""
GOT_SLUG=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --classification|--rationale|--related|--reopen-gate|--plans-root)
      FLAG="$1"
      [ $# -ge 2 ] || refuse_usage "$FLAG needs a non-empty value"
      VAL="$2"
      if [ -z "$VAL" ] && [ "$FLAG" != "--rationale" ]; then refuse_usage "$FLAG needs a non-empty value"; fi
      case "$FLAG" in
        --classification) CLASS="$VAL"; HAVE_CLASS=1 ;;
        --rationale) RATIONALE="$VAL"; HAVE_RAT=1 ;;
        --related) RELATED="$VAL" ;;
        --reopen-gate) GATE="$VAL" ;;
        --plans-root) ROOT_FLAG="$VAL" ;;
      esac
      shift 2 ;;
    -*) refuse_usage "unknown flag '$1'" ;;
    *)
      if [ "$GOT_SLUG" = 1 ]; then refuse_usage "unexpected argument '$1'"; fi
      SLUG="$1"; GOT_SLUG=1; shift ;;
  esac
done

[ -n "$SLUG" ] || refuse_usage "needs a slug"
[ "$HAVE_CLASS" = 1 ] || refuse_usage "needs --classification"
[ "$HAVE_RAT" = 1 ] || refuse_usage "needs --rationale"
command -v jq >/dev/null 2>&1 || refuse_usage "jq is required"
command -v python3 >/dev/null 2>&1 || refuse_usage "python3 is required"

TODAY="${SESSION_CLOSE_TODAY:-$(date '+%Y-%m-%d')}"

ROOT="${ROOT_FLAG:-${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}}"
case "$ROOT" in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac
while [ "${ROOT%/}" != "$ROOT" ]; do ROOT="${ROOT%/}"; done
export PLANS_ROOT="$ROOT" PLANS_DIR="$ROOT"

# The rules chain. A missing source is a refusal, not a literal fallback.
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
load_rules || refuse_note "no plans rules found"

NOTE="$ROOT/_inbox/$SLUG.md"
TMPF="$ROOT/_inbox/.$SLUG.md.tmp.$$"

IFS= read -r -d '' PY_TRIAGE <<'PY'
import json
import os
import re
import shutil
import sys

try:
    sys.stdout.reconfigure(errors="surrogateescape")
except AttributeError:
    pass

root, slug, cls, rationale, related_csv, gate, today, rules_text, tmp = sys.argv[1:10]
KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
CLASSES = ("NOVEL", "DUPLICATE", "OVERLAP", "DEFERRED")


def say(kind, text=""):
    sys.stdout.write(kind + "\t" + text + "\n")
    sys.exit(0)


def refuse(reason):
    say("REFUSE", reason)


def unq(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def fm_dict(lines):
    d = {}
    for ln in lines:
        m = KEY_RE.match(ln)
        if m and m.group(1) not in d:
            d[m.group(1)] = unq(m.group(2))
    return d


def apply_updates(lines, pairs):
    names = dict(pairs)
    seen = set()
    out = []
    for ln in lines:
        m = KEY_RE.match(ln)
        if m and m.group(1) in names:
            out.append("%s: %s" % (m.group(1), names[m.group(1)]))
            seen.add(m.group(1))
        else:
            out.append(ln)
    for k, v in pairs:
        if k not in seen:
            out.append("%s: %s" % (k, v))
    return out


try:
    rules = json.loads(rules_text)
    inbox = rules["inbox"]
    slug_pattern = inbox["slug_pattern"]
    required = inbox["note_frontmatter"]["required"]
    type_value = inbox["note_frontmatter"]["type_value"]
    status_enum = inbox["funnel_status_enum"]
    gates = inbox["reopen_gates"]
    disp_enum = rules["backlog_row"]["disposition_enum"]
except (ValueError, KeyError, TypeError):
    refuse("no plans rules found")
# plan statuses that end a plan; an absent lifecycle block or list reads as empty (every target open)
try:
    terminal_status = rules.get("lifecycle", {}).get("terminal_status", [])
except AttributeError:
    terminal_status = []
if not isinstance(terminal_status, list):
    terminal_status = []


def gate_registered(gid):
    return isinstance(gates, dict) and gid in gates and not gid.startswith("_")


# 1. slug, 2. the note, 3. its frontmatter and type, 4. one-way status
if not re.fullmatch(slug_pattern, slug):
    refuse("slug '%s' does not match inbox.slug_pattern" % slug)
note = os.path.join(root, "_inbox", slug + ".md")
if not os.path.isfile(note):
    refuse("no note _inbox/%s.md" % slug)
try:
    with open(note, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        text = fh.read()
except OSError:
    say("ERROR", "could not read _inbox/%s.md" % slug)
if not text.startswith("---\n"):
    refuse("_inbox/%s.md has no frontmatter" % slug)
end = text.find("\n---\n", 4)
if end < 0:
    refuse("_inbox/%s.md has no frontmatter" % slug)
fm_lines = text[4:end].split("\n")
fm = fm_dict(fm_lines)
if fm.get("type", "") != type_value:
    refuse("_inbox/%s.md is not an idea note" % slug)
old_status = fm.get("status", "")
if old_status != "new":
    refuse("status is '%s', not new (triage is one-way new -> triaged)" % old_status)

# 5. classification, 6. its combination rules, 7. the rationale
if cls not in CLASSES:
    refuse("--classification must be one of NOVEL, DUPLICATE, OVERLAP, DEFERRED")
members = []
related_bad = False
if related_csv:
    for part in related_csv.split(","):
        part = part.strip()
        if not NAME_RE.match(part):
            related_bad = True
        elif part not in members:
            members.append(part)
if cls == "NOVEL" and (related_csv or gate):
    refuse("NOVEL takes no --related and no --reopen-gate")
if cls == "OVERLAP":
    if related_bad or not 1 <= len(members) <= 3:
        refuse("OVERLAP needs --related with 1 to 3 slugs")
    if gate:
        refuse("OVERLAP takes no --reopen-gate")
if cls == "DUPLICATE":
    if related_bad or len(members) != 1:
        refuse("DUPLICATE needs --related with exactly 1 slug")
    if gate:
        refuse("DUPLICATE takes no --reopen-gate")
if cls == "DEFERRED" and (not gate or related_csv):
    refuse("DEFERRED needs --reopen-gate and takes no --related")
rationale = rationale.strip()
if not rationale or "\n" in rationale or "\r" in rationale:
    refuse("--rationale needs one non-empty line")

# 8. the Notes section
body = text[end + 5:]
blines = body.split("\n")
h = -1
for i, ln in enumerate(blines):
    if ln.rstrip() == "## Notes":
        h = i
        break
notes_missing = h < 0

# 9. an existing related value must be a flow list before a line edit can rewrite it
old_related = []
if cls in ("OVERLAP", "DUPLICATE"):
    for i, ln in enumerate(fm_lines):
        m = KEY_RE.match(ln)
        if not (m and m.group(1) == "related"):
            continue
        val = m.group(2).strip()
        nxt = fm_lines[i + 1] if i + 1 < len(fm_lines) else ""
        if val == "":
            if re.match(r"^\s*-(\s|$)", nxt):
                refuse("related in _inbox/%s.md is not a flow list" % slug)
        elif val.startswith("[") and val.endswith("]"):
            for item in val[1:-1].split(","):
                item = unq(item)
                if item and item not in old_related:
                    old_related.append(item)
        else:
            refuse("related in _inbox/%s.md is not a flow list" % slug)
        break

# 10. the gate, 11. DEFERRED over a decided disposition
if cls == "DEFERRED":
    if not gate_registered(gate):
        refuse("reopen gate '%s' is not registered in inbox.reopen_gates" % gate)
    cur = fm.get("disposition", "")
    if cur and cur != "NO-BUILD":
        refuse("DEFERRED would replace the decided disposition '%s'; only an undecided or NO-BUILD note is parked" % cur)

# the edit: apply_fm_updates semantics, absent keys appended in the order
# status, disposition, reopen_gate, related, updated
pairs = []
new_status = old_status
if cls in ("NOVEL", "OVERLAP"):
    pairs.append(("status", "triaged"))
    new_status = "triaged"
if cls == "DEFERRED":
    pairs.append(("disposition", "NO-BUILD"))
    pairs.append(("reopen_gate", gate))
if cls in ("OVERLAP", "DUPLICATE"):
    merged = list(old_related) + [m for m in members if m not in old_related]
    pairs.append(("related", "[" + ", ".join(merged) + "]"))
pairs.append(("updated", today))
new_fm = apply_updates(fm_lines, pairs)
edited = fm_dict(new_fm)

# 12. an ABSORB target, 13. the edited frontmatter against the rules
if edited.get("disposition", "") == "ABSORB":
    key = re.split(r"\s*::\s*", edited.get("absorbed_into", "").strip(), maxsplit=1)[0].strip()
    resolves = bool(key) and not key.startswith("/") and ".." not in key.split("/") \
        and os.path.isfile(os.path.join(root, key, "manifest.json"))
    if not resolves:
        refuse("ABSORB needs an absorbed_into target that resolves to a plan dir")
    try:
        with open(os.path.join(root, key, "manifest.json"), encoding="utf-8") as mfh:
            target_status = json.load(mfh).get("status", "")
    except (OSError, ValueError, AttributeError):
        target_status = ""
    if isinstance(target_status, str) and target_status and target_status in terminal_status:
        refuse("ABSORB target '%s' is a terminal plan (status %s); an absorbed note needs an open target"
               % (key, target_status))
for k in required:
    if not edited.get(k, "").strip():
        refuse("required key '%s' is missing or empty" % k)
if edited.get("status", "") not in status_enum:
    refuse("status '%s' is not in inbox.funnel_status_enum" % edited.get("status", ""))
disp = edited.get("disposition", "")
if disp and disp not in disp_enum:
    refuse("disposition '%s' is not in backlog_row.disposition_enum" % disp)
if disp == "NO-BUILD" and not gate_registered(edited.get("reopen_gate", "")):
    refuse("reopen gate '%s' is not registered in inbox.reopen_gates" % edited.get("reopen_gate", ""))

# the Notes line: directly after the section's last non-blank line (after the heading when empty);
# a note with no section gets the heading after the body's last non-blank line, one blank line between
notes_line = "- [backlog-triage %s] %s: %s" % (today, cls, rationale)
if notes_missing:
    head = body.rstrip("\n")
    new_body = (head + "\n\n" if head else "") + "## Notes\n\n" + notes_line + "\n"
else:
    stop = len(blines)
    for i in range(h + 1, len(blines)):
        if blines[i].startswith("## "):
            stop = i
            break
    last = h
    for i in range(h + 1, stop):
        if blines[i].strip():
            last = i
    blines.insert(last + 1, notes_line)
    new_body = "\n".join(blines)
    if not new_body.endswith("\n"):
        new_body += "\n"
new_text = text[:4] + "\n".join(new_fm) + "\n---\n" + new_body

try:
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
        fh.write(new_text)
    try:
        shutil.copymode(note, tmp)
    except OSError:
        pass
except OSError:
    say("ERROR", "could not write _inbox/%s.md" % slug)
say("OK", "%s\t%s" % (old_status, new_status))
PY

TAB=$'\t'
RES="$(python3 -c "$PY_TRIAGE" "$ROOT" "$SLUG" "$CLASS" "$RATIONALE" "$RELATED" "$GATE" "$TODAY" "$RULES_JSON" "$TMPF")"
case "$RES" in
  REFUSE"$TAB"*) refuse_note "${RES#REFUSE?}" ;;
  ERROR"$TAB"*)
    log_abort "${RES#ERROR?}"
    printf 'triage-apply: %s; nothing changed\n' "${RES#ERROR?}" >&2
    exit 1 ;;
  OK"$TAB"*) ;;
  *)
    log_abort "internal error"
    printf 'triage-apply: internal error; nothing changed\n' >&2
    exit 1 ;;
esac
OLD_STATUS="$(printf '%s' "${RES#OK?}" | cut -f1)"
NEW_STATUS="$(printf '%s' "${RES#OK?}" | cut -f2)"

if ! mv "$TMPF" "$NOTE"; then
  rm -f -- "$TMPF"
  TMPF=""
  log_abort "could not write _inbox/$SLUG.md"
  printf 'triage-apply: could not write _inbox/%s.md; nothing changed\n' "$SLUG" >&2
  exit 1
fi
TMPF=""

printf 'triage-apply: %s %s status %s -> %s\n' "$SLUG" "$CLASS" "$OLD_STATUS" "$NEW_STATUS"

# The derivation a tool-event write would have fired: the PostToolUse inbox prompt.
HOOK="${CLAUDE_HOME:-$HOME/.claude}/hooks/post-tool-use-manifest.sh"
if [ -f "$HOOK" ]; then
  CTX="$(jq -n --arg p "$NOTE" '{tool_name: "Write", tool_input: {file_path: $p}}' | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null | tr '\n' ' ')"
  CTX="${CTX%"${CTX##*[! ]}"}"
  if [ -n "$CTX" ]; then printf 'NOTE: %s\n' "$CTX" >&2; fi
else
  printf 'NOTE: inbox-triage prompt skipped (%s is missing)\n' "$HOOK" >&2
fi
printf 'triage-apply: run /librarian backlog-index to refresh the backlog\n' >&2
exit 0
