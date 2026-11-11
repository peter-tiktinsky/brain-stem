#!/usr/bin/env bash
# reopen-idea.sh - re-open one parked idea whose re-open gate is manual (or, with --force, a
# registered command gate): the settled note `_inbox/_settled/<slug>.md` (type idea, disposition
# NO-BUILD, a registered gate in reopen_gate) moves back to `_inbox/<slug>.md` as an open,
# undecided note.
#
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/backlog-triage/scripts/reopen-idea.sh <slug> [--force] [--plans-root DIR]
#
# THE EDIT is the one backlog-index applies when a command gate is met: the resolution and
# resolved_at lines are dropped, disposition is left bare, updated, reopened_at and
# reopened_from_gate are set (an existing line replaced in place, an absent one appended in
# that order), and the body is byte-untouched. The gate kind is read from inbox.reopen_gates in
# the plans rules; this command never evaluates a gate. A command gate is refused unless --force
# is given: backlog-index re-opens that note when the gate is met, and --force is the operator's
# override for a gate that cannot be met (a retired reader, a decision taken by hand). --force
# skips only the command-gate refusal: the gate must still be registered in inbox.reopen_gates,
# no gate is evaluated, and THE EDIT is unchanged. The success line carries `; forced` when
# --force bypassed a command gate, and is the plain line on a manual gate.
#
# STATES: a settled parked note and no flat note: the move runs. A flat note and no settled copy:
# already open, nothing written, exit 0. Both exist and the flat note's reopened_from_gate equals
# the settled copy's reopen_gate and the two bodies are equal: an earlier run stopped after the
# rename, so the settled copy is removed and the re-open is finished. Both exist otherwise: refused.
#
# EXIT CODES: 0 done or already open; 2 refused with every byte unchanged; 1 stopped (the message
# names what changed and the re-run command). A refusal prints `reopen-idea: refused: <reason>`.
#
# RULES come from the plans-rules chain: PLANS_RULES_PATH, then
# ${CLAUDE_HOME:-$HOME/.claude}/governance/plans-rules.json, then
# foundation-overlay-load.sh --query '.plans' --force-override. The plans root is --plans-root,
# else PLANS_ROOT, else PLANS_DIR as hooks/lib/paths.sh resolves it, else $HOME/.claude-plans;
# the resolved root is exported as both PLANS_ROOT and PLANS_DIR before any child runs.
#
# WRITE: the edited text goes to a temp file `.<slug>.md.tmp.<pid>` in _inbox (never ending .md,
# so no *.md glob reads it), a PATH-resolved plain `mv` places it at _inbox/<slug>.md, and a
# PATH-resolved plain `rm` then removes the settled copy. A trap on EXIT, INT, TERM and HUP
# removes the temp file. No lock is taken. While both copies exist backlog-index reads the
# settled copy's manual gate and skips it, so the pair raises no finding; a re-run closes it.
#
# DERIVATIONS a tool-event write of the note would have fired, run here because a script write
# fires none: on the call that completes the re-open (after the settled copy is removed) the
# PostToolUse hook post-tool-use-manifest.sh runs once with the Write payload for the open note,
# and its inbox prompt (an empty or out-of-enum disposition) is relayed as one `NOTE:` line on
# stderr. A missing hook prints a `NOTE:` and the command still succeeds. This command never
# runs backlog-index and never writes _backlog.md: run /librarian backlog-index to refresh it.
#
# Bash 3.2 clean. Data reaches python through argv, never a piped stdin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$0"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../hooks/lib/paths.sh" 2>/dev/null || true
set -u

TMPF=""

usage() {
  printf 'usage: reopen-idea <slug> [--force] [--plans-root DIR]\n'
  printf 'exit: 0 reopened or already open; 2 refused (nothing changed); 1 stopped (the message names the re-run)\n'
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

refuse() {
  printf 'reopen-idea: refused: %s\n' "$1" >&2
  exit 2
}

SLUG=""; GOT_SLUG=0; ROOT_FLAG=""; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1; shift ;;
    --plans-root)
      [ $# -ge 2 ] || refuse "--plans-root needs a non-empty value"
      [ -n "$2" ] || refuse "--plans-root needs a non-empty value"
      ROOT_FLAG="$2"; shift 2 ;;
    -*) refuse "unknown flag '$1'" ;;
    *)
      if [ "$GOT_SLUG" = 1 ]; then refuse "unexpected argument '$1'"; fi
      SLUG="$1"; GOT_SLUG=1; shift ;;
  esac
done

[ -n "$SLUG" ] || refuse "needs a slug"
command -v jq >/dev/null 2>&1 || refuse "jq is required"
command -v python3 >/dev/null 2>&1 || refuse "python3 is required"

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
load_rules || refuse "no plans rules found"

FLAT="$ROOT/_inbox/$SLUG.md"
SETTLED="$ROOT/_inbox/_settled/$SLUG.md"
TMPF="$ROOT/_inbox/.$SLUG.md.tmp.$$"

IFS= read -r -d '' PY_REOPEN <<'PY'
import json
import os
import re
import shutil
import sys

try:
    sys.stdout.reconfigure(errors="surrogateescape")
except AttributeError:
    pass

root, slug, today, rules_text, tmp, force = sys.argv[1:7]
KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")


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


def split_note(text):
    """(frontmatter lines, index of the closing fence) or (None, -1) when there is no frontmatter."""
    if not text.startswith("---\n"):
        return None, -1
    end = text.find("\n---\n", 4)
    if end < 0:
        return None, -1
    return text[4:end].split("\n"), end


def fm_dict(lines):
    d = {}
    for ln in lines:
        m = KEY_RE.match(ln)
        if m and m.group(1) not in d:
            d[m.group(1)] = unq(m.group(2))
    return d


def read(path):
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        return fh.read()


try:
    rules = json.loads(rules_text)
    inbox = rules["inbox"]
    slug_pattern = inbox["slug_pattern"]
    type_value = inbox["note_frontmatter"]["type_value"]
    gates = inbox["reopen_gates"]
except (ValueError, KeyError, TypeError):
    refuse("no plans rules found")

if not re.fullmatch(slug_pattern, slug):
    refuse("slug '%s' does not match inbox.slug_pattern" % slug)
flat = os.path.join(root, "_inbox", slug + ".md")
settled = os.path.join(root, "_inbox", "_settled", slug + ".md")
if not os.path.isfile(settled):
    if os.path.isfile(flat):
        say("OPEN")
    refuse("no parked note _inbox/_settled/%s.md" % slug)
try:
    text = read(settled)
except OSError:
    refuse("no parked note _inbox/_settled/%s.md" % slug)
lines, end = split_note(text)
fm = fm_dict(lines) if lines is not None else {}
if lines is None or fm.get("type", "") != type_value or fm.get("disposition", "") != "NO-BUILD":
    refuse("_inbox/_settled/%s.md is not a parked NO-BUILD note" % slug)
gate = fm.get("reopen_gate", "")
entry = gates.get(gate) if (gate and isinstance(gates, dict)) else None
if not isinstance(entry, dict) or gate.startswith("_"):
    refuse("reopen gate '%s' is not registered in inbox.reopen_gates" % gate)
kind = entry.get("kind")
forced = False
if kind == "command":
    if force != "1":
        refuse("gate '%s' is a command gate; backlog-index re-opens the note when the gate is met" % gate)
    forced = True
elif kind != "manual":
    refuse("reopen gate '%s' is not registered in inbox.reopen_gates" % gate)

if os.path.isfile(flat):
    try:
        flat_text = read(flat)
    except OSError:
        flat_text = ""
    flat_lines, flat_end = split_note(flat_text)
    flat_fm = fm_dict(flat_lines) if flat_lines is not None else {}
    if flat_lines is not None and flat_fm.get("reopened_from_gate", "") == gate \
            and flat_text[flat_end + 5:] == text[end + 5:]:
        say("RESUME", gate + ("\tforced" if forced else ""))
    refuse("_inbox/%s.md already exists and is not this note's reopened copy" % slug)

# the edit backlog-index applies on a met command gate, byte for byte
updates = {"updated": today, "reopened_at": today, "reopened_from_gate": gate}
out = []
seen = set()
for ln in lines:
    m = KEY_RE.match(ln)
    name = m.group(1) if m else None
    if name in ("resolution", "resolved_at"):
        continue
    if name == "disposition":
        out.append("disposition:")
        continue
    if name in updates:
        out.append("%s: %s" % (name, updates[name]))
        seen.add(name)
        continue
    out.append(ln)
for k in ("updated", "reopened_at", "reopened_from_gate"):
    if k not in seen:
        out.append("%s: %s" % (k, updates[k]))
new_text = "---\n" + "\n".join(out) + text[end:]
try:
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
        fh.write(new_text)
    try:
        shutil.copymode(settled, tmp)
    except OSError:
        pass
except OSError:
    say("ERROR", "could not place _inbox/%s.md" % slug)
say("REOPEN", gate + ("\tforced" if forced else ""))
PY

TAB=$'\t'
RES="$(python3 -c "$PY_REOPEN" "$ROOT" "$SLUG" "$TODAY" "$RULES_JSON" "$TMPF" "$FORCE")"
case "$RES" in
  REFUSE"$TAB"*) refuse "${RES#REFUSE?}" ;;
  OPEN"$TAB"*)
    printf 'reopen-idea: %s is already open\n' "$SLUG"
    exit 0 ;;
  ERROR"$TAB"*)
    printf 'reopen-idea: %s; nothing changed\n' "${RES#ERROR?}" >&2
    exit 1 ;;
  REOPEN"$TAB"*) MODE=reopen; GATE="${RES#REOPEN?}" ;;
  RESUME"$TAB"*) MODE=resume; GATE="${RES#RESUME?}"; TMPF="" ;;
  *)
    printf 'reopen-idea: internal error; nothing changed\n' >&2
    exit 1 ;;
esac

FORCED_NOTE=""
case "$GATE" in
  *"$TAB"*) FORCED_NOTE="; forced"; GATE="${GATE%%"$TAB"*}" ;;
esac

if [ "$MODE" = reopen ]; then
  if ! mv "$TMPF" "$FLAT"; then
    rm -f -- "$TMPF"
    TMPF=""
    printf 'reopen-idea: could not place _inbox/%s.md; nothing changed\n' "$SLUG" >&2
    exit 1
  fi
  TMPF=""
fi

if ! rm "$SETTLED"; then
  printf 'reopen-idea: stopped after the move; re-run: bash %s %s\n' "$SELF" "$SLUG" >&2
  exit 1
fi

printf 'reopen-idea: reopened %s (gate %s%s)\n' "$SLUG" "$GATE" "$FORCED_NOTE"
printf 'reopen-idea: run /librarian backlog-index to refresh _backlog.md\n'

# The derivation a tool-event write would have fired: the PostToolUse inbox prompt.
HOOK="${CLAUDE_HOME:-$HOME/.claude}/hooks/post-tool-use-manifest.sh"
if [ -f "$HOOK" ]; then
  CTX="$(jq -n --arg p "$FLAT" '{tool_name: "Write", tool_input: {file_path: $p}}' | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null | tr '\n' ' ')"
  CTX="${CTX%"${CTX##*[! ]}"}"
  if [ -n "$CTX" ]; then printf 'NOTE: %s\n' "$CTX" >&2; fi
else
  printf 'NOTE: inbox-triage prompt skipped (%s is missing)\n' "$HOOK" >&2
fi
exit 0
