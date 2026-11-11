#!/usr/bin/env bash
# redecide-idea.sh - replace, or clear, the decided disposition of one flat idea note
# `_inbox/<slug>.md`, so that the note either carries a new decision or is undecided and can be
# taken by the next `promote-from-inbox.sh <lead> --absorb <slug>`.
#
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/backlog-triage/scripts/redecide-idea.sh <slug>
#     (--disposition <value> [--absorbed-into <plan-key>] [--release-class <c> --size <s>] [--reopen-gate <id>]
#      | --clear) --rationale <one line> [--plans-root DIR]
#
# VALUES AND CLASS FLAGS are those of a capture. ABSORB needs --absorbed-into, a plan key (an
# optional ' :: T-N' suffix stripped) whose manifest.json exists under the plans root and whose
# status is not in lifecycle.terminal_status (an absent status is open). STANDALONE needs
# --release-class and --size from inbox.note_frontmatter. NO-BUILD needs --reopen-gate, an id
# registered in inbox.reopen_gates and not `_`-prefixed. FIX NOW is refused. A class flag with any
# other value is refused. --clear takes no disposition or class flag. The note's funnel status is
# never a condition and is never written. A NO-BUILD re-decide parks a decided or undecided note
# in one step: triage-apply.sh refuses DEFERRED over a decided disposition.
#
# THE EDIT: the `disposition` line is replaced in place (`disposition: <value>`, or the bare
# `disposition:` with --clear). Every dependent key the old decision carried and the new one does
# not (absorbed_into, release_class, size, reopen_gate) is removed. The new value's keys are
# replaced in place when present, else appended after the last frontmatter line in the order
# absorbed_into, release_class, size, reopen_gate; an absorbed_into value containing ' :: ' is
# written double-quoted, a bare key bare. `updated` is set to today (replaced in place, else
# appended last). Every other key and the body are untouched except one appended line,
# `- [backlog-triage <today>] REDECIDE <old> -> <new>: <rationale>` (<old> the old value or
# `undecided`, <new> the new value or `cleared`), written directly after the last non-blank line
# of the `## Notes` section. A note with no such section gets the heading after the body's last
# non-blank line, one blank line between each part.
#
# REFUSED, the note byte-identical: a note that is settled, graduated to a plan, absent, without
# frontmatter, not an idea, or already carrying absorbed_into, promoted_to or resolution (a
# targeted or settled note is not re-decided; reopen-idea.sh re-opens a parked one, and a plan's
# disposition is set with field-set.sh); a rationale that is not one non-empty line; a value or
# class flag combination outside the rules; a decision the note already carries; --clear on an
# undecided note. The edited frontmatter is validated against inbox.note_frontmatter.required and
# inbox.funnel_status_enum before the write.
#
# EXIT CODES: 0 done; 2 refused with the note byte-identical; 1 the write failed (nothing
# changed). A refusal prints `redecide-idea: refused: <reason>` as the last stderr line. A refusal
# after the arguments parse (a note-class refusal or a failed write) also appends one
# `redecide-aborted` JSON line to $HOOKS_STATE/backlog-triage-errors.jsonl; a usage-class refusal
# (an unknown flag, an empty value, a missing slug, rationale or decision) logs nothing.
#
# RULES come from the plans-rules chain: PLANS_RULES_PATH, then
# ${CLAUDE_HOME:-$HOME/.claude}/governance/plans-rules.json, then
# foundation-overlay-load.sh --query '.plans' --force-override. The plans root is --plans-root,
# else PLANS_ROOT, else PLANS_DIR as hooks/lib/paths.sh resolves it, else $HOME/.claude-plans;
# the resolved root is exported as both PLANS_ROOT and PLANS_DIR before any child runs.
#
# WRITE: the edited text goes to a temp file `.<slug>.md.tmp.<pid>` in _inbox (never ending .md,
# so no *.md glob reads it) and a PATH-resolved plain `mv` renames it over the note. A trap on
# EXIT, INT, TERM and HUP removes the temp file. No lock is taken. The command edits this one note
# and nothing else: no manifest, no settled note, no second note, no index.
#
# DERIVATIONS a tool-event write of the note would have fired, run here because a script write
# fires none: after a successful write the PostToolUse hook post-tool-use-manifest.sh runs once
# with the Write payload for the note, and its inbox prompt (an empty disposition is prompted
# for) is relayed as one `NOTE:` line on stderr. A missing hook prints a `NOTE:` and the command
# still succeeds. This command never runs backlog-index and never writes _backlog.md: the operator
# runs /librarian backlog-index to refresh the view.
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
  printf 'usage: redecide-idea <slug> (--disposition <value> [--absorbed-into <plan-key>] [--release-class <c> --size <s>] [--reopen-gate <id>] | --clear) --rationale <one line> [--plans-root DIR]\n'
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
  printf 'redecide-idea: refused: %s\n' "$1" >&2
  exit 2
}

# log_abort <reason>: one redecide-aborted line in the diagnostic file the triage skill names.
log_abort() {
  [ -n "${HOOKS_STATE:-}" ] || return 0
  # swallow-ok: reports=stderr the refusal or failure line is printed by the caller; the diagnostic log is best effort
  mkdir -p "$HOOKS_STATE" 2>/dev/null || return 0
  # swallow-ok: reports=stderr the refusal or failure line is printed by the caller; the diagnostic log is best effort
  jq -cn --arg s "$SLUG" --arg r "$1" --arg d "$TODAY" \
    '{finding: "redecide-aborted", inbox_slug: $s, reason: $r, detected_at: $d}' \
    >> "$HOOKS_STATE/backlog-triage-errors.jsonl" 2>/dev/null || return 0
}

# refuse_note <reason>: a note-class refusal; logged, then the usage-style line and exit 2.
refuse_note() {
  log_abort "$1"
  printf 'redecide-idea: refused: %s\n' "$1" >&2
  exit 2
}

DISP=""; HAVE_DISP=0; CLEAR=0; RATIONALE=""; HAVE_RAT=0; ABS=""; HAVE_ABS=0
RCLASS=""; HAVE_RC=0; SIZE=""; HAVE_SZ=0; GATE=""; HAVE_GATE=0; ROOT_FLAG=""
GOT_SLUG=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --clear) CLEAR=1; shift ;;
    --disposition|--absorbed-into|--release-class|--size|--reopen-gate|--rationale|--plans-root)
      FLAG="$1"
      [ $# -ge 2 ] || refuse_usage "$FLAG needs a non-empty value"
      VAL="$2"
      [ -n "$VAL" ] || refuse_usage "$FLAG needs a non-empty value"
      case "$FLAG" in
        --disposition) DISP="$VAL"; HAVE_DISP=1 ;;
        --absorbed-into) ABS="$VAL"; HAVE_ABS=1 ;;
        --release-class) RCLASS="$VAL"; HAVE_RC=1 ;;
        --size) SIZE="$VAL"; HAVE_SZ=1 ;;
        --reopen-gate) GATE="$VAL"; HAVE_GATE=1 ;;
        --rationale) RATIONALE="$VAL"; HAVE_RAT=1 ;;
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
[ "$HAVE_RAT" = 1 ] || refuse_usage "needs --rationale"
if [ "$HAVE_DISP" = 0 ] && [ "$CLEAR" = 0 ]; then refuse_usage "needs --disposition or --clear"; fi
if [ "$CLEAR" = 1 ] && [ "$((HAVE_DISP + HAVE_ABS + HAVE_RC + HAVE_SZ + HAVE_GATE))" -gt 0 ]; then
  refuse_usage "--clear takes no --disposition or class flag"
fi
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

IFS= read -r -d '' PY_REDECIDE <<'PY'
import json
import os
import re
import shutil
import sys

try:
    sys.stdout.reconfigure(errors="surrogateescape")
except AttributeError:
    pass

(root, slug, clear_flag, disp_set, disp, abs_set, abs_val, rc_set, rclass, sz_set, size,
 gate_set, gate, rationale, today, rules_text, tmp) = sys.argv[1:18]
clear = clear_flag == "1"
KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")
DEP_KEYS = ("absorbed_into", "release_class", "size", "reopen_gate")


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


try:
    rules = json.loads(rules_text)
    inbox = rules["inbox"]
    slug_pattern = inbox["slug_pattern"]
    nf = inbox["note_frontmatter"]
    required = nf["required"]
    type_value = nf["type_value"]
    classes = nf["release_class_enum"]
    sizes = nf["size_enum"]
    status_enum = inbox["funnel_status_enum"]
    gates = inbox["reopen_gates"]
    disp_enum = rules["backlog_row"]["disposition_enum"]
except (ValueError, KeyError, TypeError):
    refuse("no plans rules found")
try:
    terminal_status = rules.get("lifecycle", {}).get("terminal_status", [])
except AttributeError:
    terminal_status = []
if not isinstance(terminal_status, list):
    terminal_status = []
settled_rel = inbox.get("settled_dir", "_inbox/_settled/").strip("/")


def gate_registered(gid):
    return isinstance(gates, dict) and gid in gates and not gid.startswith("_")


# 1. the slug
if not re.fullmatch(slug_pattern, slug):
    refuse("slug '%s' does not match inbox.slug_pattern" % slug)
note = os.path.join(root, "_inbox", slug + ".md")

# 2. a settled or graduated note has no flat copy
if not os.path.isfile(note):
    if os.path.isfile(os.path.join(root, *settled_rel.split("/"), slug + ".md")):
        refuse("_inbox/_settled/%s.md is settled; a parked note is re-opened with reopen-idea.sh "
               "and no other settlement is re-decided" % slug)
    try:
        entries = sorted(os.listdir(root))
    except OSError:
        entries = []
    for entry in entries:
        mpath = os.path.join(root, entry, "manifest.json")
        if entry.startswith((".", "_")) or not os.path.isfile(mpath):
            continue
        try:
            with open(mpath, encoding="utf-8") as mfh:
                promoted = json.load(mfh).get("promoted_from", "")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(promoted, str) and promoted.strip() == "_inbox/%s.md" % slug:
            refuse("'%s' graduated to %s; a plan's disposition is set with field-set.sh" % (slug, entry))
    refuse("no note _inbox/%s.md" % slug)

# 3. its frontmatter and type
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

# 4. a targeted or settled note is not re-decided
for k in ("absorbed_into", "promoted_to", "resolution"):
    if fm.get(k, "").strip():
        refuse("the note already carries %s; a targeted or settled note is not re-decided" % k)

# 5. the rationale
rationale = rationale.strip()
if not rationale or "\n" in rationale or "\r" in rationale:
    refuse("--rationale needs one non-empty line")

# 6. the new decision
old_disp = fm.get("disposition", "")
new_keys = []
if not clear:
    if disp not in disp_enum:
        refuse("--disposition must be one of %s" % ", ".join(disp_enum))
    if disp == "FIX NOW":
        refuse("--disposition 'FIX NOW' is not a note value: a fix-now item is fixed, not captured")
    if abs_set == "1" and disp != "ABSORB":
        refuse("--absorbed-into applies to --disposition ABSORB only")
    if (rc_set == "1" or sz_set == "1") and disp != "STANDALONE":
        refuse("--release-class and --size apply to --disposition STANDALONE only")
    if gate_set == "1" and disp != "NO-BUILD":
        refuse("--reopen-gate applies to --disposition NO-BUILD only")
    if disp == "ABSORB":
        key = re.split(r"\s*::\s*", abs_val, maxsplit=1)[0].strip() if abs_set == "1" else ""
        mpath = os.path.join(root, key, "manifest.json")
        if (not key or key.startswith("/") or ".." in key.split("/") or not os.path.isfile(mpath)):
            refuse("--disposition ABSORB requires --absorbed-into <plan-key> that resolves to a plan "
                   "dir with a manifest.json")
        try:
            with open(mpath, encoding="utf-8") as mfh:
                target_status = json.load(mfh).get("status", "")
        except (OSError, ValueError, AttributeError):
            target_status = ""
        if isinstance(target_status, str) and target_status and target_status in terminal_status:
            refuse("--absorbed-into '%s' names a terminal plan (status %s); an absorbed note needs an "
                   "open target" % (abs_val, target_status))
        new_keys = [("absorbed_into", '"%s"' % abs_val.replace("\\", "\\\\").replace('"', '\\"')
                     if " :: " in abs_val else abs_val)]
    elif disp == "STANDALONE":
        if rc_set != "1" or rclass not in classes or sz_set != "1" or size not in sizes:
            refuse("--disposition STANDALONE requires --release-class one of %s and --size one of %s"
                   % (", ".join(classes), ", ".join(sizes)))
        new_keys = [("release_class", rclass), ("size", size)]
    elif disp == "NO-BUILD":
        if gate_set != "1" or not gate_registered(gate):
            refuse("--disposition NO-BUILD requires --reopen-gate <id> naming a gate in "
                   "inbox.reopen_gates")
        new_keys = [("reopen_gate", gate)]

# 7. the edit
new_disp_text = "" if clear else disp
drop = set(DEP_KEYS) - set(k for k, _ in new_keys)
new_vals = dict(new_keys)
out = []
seen = set()
for ln in fm_lines:
    m = KEY_RE.match(ln)
    name = m.group(1) if m else None
    if name == "disposition":
        out.append("disposition: %s" % new_disp_text if new_disp_text else "disposition:")
        seen.add("disposition")
    elif name in drop:
        continue
    elif name in new_vals:
        out.append("%s: %s" % (name, new_vals[name]))
        seen.add(name)
    elif name == "updated":
        out.append("updated: %s" % today)
        seen.add("updated")
    else:
        out.append(ln)
if "disposition" not in seen:
    out.append("disposition: %s" % new_disp_text if new_disp_text else "disposition:")
for k in DEP_KEYS:
    if k in new_vals and k not in seen:
        out.append("%s: %s" % (k, new_vals[k]))
if "updated" not in seen:
    out.append("updated: %s" % today)

# 8. nothing to change
if clear:
    if not old_disp:
        refuse("'%s' is already undecided; nothing to clear" % slug)
else:
    same = [ln for ln in out if not ln.startswith("updated:")] == [ln for ln in fm_lines if not ln.startswith("updated:")]
    if same and old_disp == disp:
        refuse("'%s' already carries %s with the same keys; nothing to re-decide" % (slug, disp))

# 9. the edited frontmatter against the rules
edited = fm_dict(out)
for k in required:
    if not edited.get(k, "").strip():
        refuse("required key '%s' is missing or empty" % k)
if edited.get("status", "") not in status_enum:
    refuse("status '%s' is not in inbox.funnel_status_enum" % edited.get("status", ""))

# 10. the Notes line
old_label = old_disp if old_disp else "undecided"
new_label = "cleared" if clear else disp
notes_line = "- [backlog-triage %s] REDECIDE %s -> %s: %s" % (today, old_label, new_label, rationale)
body = text[end + 5:]
blines = body.split("\n")
h = -1
for i, ln in enumerate(blines):
    if ln.rstrip() == "## Notes":
        h = i
        break
if h < 0:
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
    if last == h:
        # an empty section: the line sits one blank line under the heading, one blank line above
        # the next heading
        ins = ["", notes_line]
        if stop < len(blines):
            ins.append("")
        # drop blank lines the empty section already held so the spacing is exactly one
        k = h + 1
        while k < stop and not blines[k].strip():
            k += 1
        blines[h + 1:k] = ins
    else:
        blines.insert(last + 1, notes_line)
    new_body = "\n".join(blines)
    if not new_body.endswith("\n"):
        new_body += "\n"
new_text = text[:4] + "\n".join(out) + "\n---\n" + new_body

try:
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
        fh.write(new_text)
    try:
        shutil.copymode(note, tmp)
    except OSError:
        pass
except OSError:
    say("ERROR", "could not write _inbox/%s.md" % slug)
say("OK", "%s\t%s" % (old_label, new_label))
PY

TAB=$'\t'
RES="$(python3 -c "$PY_REDECIDE" "$ROOT" "$SLUG" "$CLEAR" "$HAVE_DISP" "$DISP" "$HAVE_ABS" "$ABS" "$HAVE_RC" "$RCLASS" "$HAVE_SZ" "$SIZE" "$HAVE_GATE" "$GATE" "$RATIONALE" "$TODAY" "$RULES_JSON" "$TMPF")"
case "$RES" in
  REFUSE"$TAB"*) refuse_note "${RES#REFUSE?}" ;;
  ERROR"$TAB"*)
    log_abort "${RES#ERROR?}"
    printf 'redecide-idea: %s; nothing changed\n' "${RES#ERROR?}" >&2
    exit 1 ;;
  OK"$TAB"*) ;;
  *)
    log_abort "internal error"
    printf 'redecide-idea: internal error; nothing changed\n' >&2
    exit 1 ;;
esac
OLD_LABEL="$(printf '%s' "${RES#OK?}" | cut -f1)"
NEW_LABEL="$(printf '%s' "${RES#OK?}" | cut -f2)"

if ! mv "$TMPF" "$NOTE"; then
  rm -f -- "$TMPF"
  TMPF=""
  log_abort "could not write _inbox/$SLUG.md"
  printf 'redecide-idea: could not write _inbox/%s.md; nothing changed\n' "$SLUG" >&2
  exit 1
fi
TMPF=""

printf 'redecide-idea: %s %s -> %s\n' "$SLUG" "$OLD_LABEL" "$NEW_LABEL"

# The derivation a tool-event write would have fired: the PostToolUse inbox prompt.
HOOK="${CLAUDE_HOME:-$HOME/.claude}/hooks/post-tool-use-manifest.sh"
if [ -f "$HOOK" ]; then
  CTX="$(jq -n --arg p "$NOTE" '{tool_name: "Write", tool_input: {file_path: $p}}' | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null | tr '\n' ' ')"
  CTX="${CTX%"${CTX##*[! ]}"}"
  if [ -n "$CTX" ]; then printf 'NOTE: %s\n' "$CTX" >&2; fi
else
  printf 'NOTE: inbox-triage prompt skipped (%s is missing)\n' "$HOOK" >&2
fi
printf 'redecide-idea: run /librarian backlog-index to refresh the backlog\n' >&2
exit 0
