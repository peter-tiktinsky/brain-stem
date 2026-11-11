#!/bin/bash
# migration: 0013-inbox-deferred-converge
# min_from: v0.0.0
# applies_at: v1.19.1
#
# Converge every flat inbox idea note that still carries the retired disposition
# DEFERRED onto the current vocabulary. The disposition enum in
# governance/plans-rules.json (backlog_row.disposition_enum) no longer lists
# DEFERRED: a parked decision is NO-BUILD with a registered re-open gate. A note
# written before that change still reads `disposition: DEFERRED`, so
# `/librarian backlog-index` reports `inbox-disposition-out-of-enum` for it, and
# triage-apply.sh cannot re-decide it. This migration rewrites each such note in
# place so the finding clears without a hand edit:
#     disposition: DEFERRED   ->   disposition: NO-BUILD
#     reopen_gate:            kept when the note names one, else set to `manual`
#     updated:                set to today
#     body                    one line appended under `## Notes`:
#                             - [migration 0013] DEFERRED -> NO-BUILD (reopen_gate <id>)
# `status` and every other key and body byte are untouched. Settlement is
# backlog-index's own closure loop: its next run parks each converted note whose gate
# is registered (`manual` is) under _inbox/_settled/. To take one up again, run
# skills/backlog-triage/scripts/reopen-idea.sh, then redecide-idea.sh.
#
# WHAT IS READ. Only the regular files `<root>/_inbox/*.md` whose names do not begin
# with `_` or `.`; the walk never descends, so `_inbox/_settled/` and `_inbox/_index.md`
# are never read. A file is a candidate only when its first line is `---`, a later line
# equal to `---` closes the frontmatter, its `type:` is `idea`, and its first
# `disposition:` line inside the frontmatter is the exact token DEFERRED (bare, or inside
# one matching pair of single or double quotes).
#
# MAP-KNOWN-LEAVE-REST, never abort. Everything that is not a candidate is left
# byte-identical and silent: another disposition value, `deferred` in lower case,
# `DEFERRED later`, an empty value, another type, a file with no frontmatter. A
# candidate whose frontmatter carries a non-empty absorbed_into, promoted_to or
# resolution is a targeted or settled note, which redecide-idea.sh does not re-decide
# either: it is left byte-identical with one stderr line naming the file, and is not
# counted as deferred (nothing failed).
#
# Recoverability (the corpus mutation is OUTSIDE install.sh's rollback envelope — the
# journal is $CLAUDE_HOME-keyed and the plans corpus is not pre-snapshotted): before a
# note is rewritten its ORIGINAL bytes are copied to a WRITE-ONCE pre-image sidecar
# `<slug>.md.pre-0013` beside it (guarded if-not-exists, so a converged re-run adds none
# and never clobbers the first pre-image, and the copy is a temp-and-rename so an
# interrupted copy leaves no truncated sidecar). Recovery: restore a note from its
# sidecar. Cleanup: the `.pre-0013` sidecars are recovery artifacts that nothing reads
# (no reader matches a name that does not end `.md`), safe to delete once the upgrade is
# verified.
#
# Root resolution: MIGRATION_PLANS_ROOT (test seam) -> PLANS_DIR_DEAD (dead-root
# redirect) -> PLANS_DIR -> $HOME/.claude-plans. An absent plans root, or a root with no
# `_inbox`, is a no-op (rc 0 — the oldest/empty precondition). Each rewrite is a temp
# file in _inbox renamed over the note, preserving the file mode. Convergent +
# idempotent: after the conversion no note is a candidate, so a re-run rewrites nothing.
# `today` is SESSION_CLOSE_TODAY when set, else the system date.
#
# Deferral exit. A note whose sidecar, rewrite or read fails (a read-only or unreadable
# _inbox, an unreadable note, a full disk) is left byte-identical and the run continues
# (an _inbox that cannot be listed counts as one such note). Each failure names its path and
# reason on one stderr line as it happens, `0013: cannot read <path>: <reason>` or `0013: cannot
# rewrite <path>: <reason>` (the _inbox or the note, and the OS error); the run then prints one
# `deferred:` line, last on stderr, and exits MIGRATION_DEFER_RC (the runner maps it to
# not-applied, so this id stays armed and the next upgrade retries; see run-migrations.sh,
# "THE 'RAN, BUT DEFERRED' PROTOCOL"). With no runner MIGRATION_DEFER_RC is unset and the exit is 0.
#
# FAIL-CLOSED on missing tooling: python3 is required to rewrite the notes safely; if it
# is absent this migration exits rc 1 with a remediation message so run-migrations halts
# the chain and the foundation_version is not bumped. That is the ONLY abort path.
#
# Advisories go to stderr; stdout stays clean for the runner.
# bash-3.2 clean; set -u.
set -u

# --- tooling gate: FAIL-CLOSED on missing python3 ---------------------------
if ! command -v python3 >/dev/null 2>&1; then
  printf '0013: python3 not on PATH — cannot converge the inbox safely; FAIL-CLOSED (rc 1). Remediation: install python3 (>=3.6) and re-run the upgrade so the migration chain can complete.\n' >&2
  exit 1
fi

# --- root resolution --------------------------------------------------------
if [ -n "${MIGRATION_PLANS_ROOT:-}" ]; then
  PLANS_ROOT="$MIGRATION_PLANS_ROOT"
elif [ -n "${PLANS_DIR_DEAD:-}" ]; then
  PLANS_ROOT="$PLANS_DIR_DEAD"
elif [ -n "${PLANS_DIR:-}" ]; then
  PLANS_ROOT="$PLANS_DIR"
else
  PLANS_ROOT="$HOME/.claude-plans"
fi
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

# --- oldest/empty precondition: absent plans root or no _inbox -> no-op -----
if [ -z "$PLANS_ROOT" ] || [ ! -d "$PLANS_ROOT" ]; then
  printf '0013: plans root absent (%s) — no-op (nothing to migrate)\n' "${PLANS_ROOT:-<unset>}" >&2
  exit 0
fi
if [ ! -d "$PLANS_ROOT/_inbox" ]; then
  printf '0013: no _inbox under %s — no-op (nothing to migrate)\n' "$PLANS_ROOT" >&2
  exit 0
fi

TODAY="${SESSION_CLOSE_TODAY:-$(date '+%Y-%m-%d')}"

# --- walk + in-place conversion (data on argv; program on stdin) ------------
python3 - "$PLANS_ROOT" "$TODAY" <<'PY'
import os, re, stat, sys, tempfile

plans_root, today = sys.argv[1], sys.argv[2]
inbox = os.path.join(plans_root, "_inbox")

KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")
TARGET_KEYS = ("absorbed_into", "promoted_to", "resolution")
NOTES_HEADING = "## Notes"


def unq(value):
    # strip outer whitespace, then ONE matching pair of single or double quotes
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def first_values(fm_lines):
    # key -> value of the FIRST line carrying that key
    d = {}
    for ln in fm_lines:
        m = KEY_RE.match(ln)
        if m and m.group(1) not in d:
            d[m.group(1)] = m.group(2)
    return d


def split_note(text):
    # (lines, closing index) when the text opens and closes a frontmatter, else None
    lines = text.split("\n")
    if len(lines) < 2 or lines[0] != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i] == "---":
            return lines, i
    return None


def convert(lines, close):
    # the edited text of a candidate, plus the gate id now on the note
    fm = lines[1:close]
    vals = first_values(fm)
    have_gate_line = "reopen_gate" in vals
    gate_raw = vals.get("reopen_gate", "")
    gate_empty = gate_raw.strip() in ("", '""', "''")
    gate_id = "manual" if gate_empty else unq(gate_raw)
    out = []
    seen = set()
    for ln in fm:
        m = KEY_RE.match(ln)
        name = m.group(1) if m else None
        if name == "disposition" and "disposition" not in seen:
            out.append("disposition: NO-BUILD")
            seen.add("disposition")
            if not have_gate_line:
                out.append("reopen_gate: manual")
        elif name == "reopen_gate" and "reopen_gate" not in seen:
            out.append("reopen_gate: manual" if gate_empty else ln)
            seen.add("reopen_gate")
        elif name == "updated" and "updated" not in seen:
            out.append("updated: %s" % today)
            seen.add("updated")
        else:
            out.append(ln)
    if "updated" not in seen:
        out.append("updated: %s" % today)
    notes_line = "- [migration 0013] DEFERRED -> NO-BUILD (reopen_gate %s)" % gate_id
    head = "\n".join(["---"] + out + ["---"])
    blines = lines[close + 1:]
    h = -1
    for i, ln in enumerate(blines):
        if ln.rstrip() == NOTES_HEADING:
            h = i
            break
    if h < 0:
        body = "\n".join(blines).rstrip("\n")
        new_body = body + "\n\n" + NOTES_HEADING + "\n\n" + notes_line + "\n"
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
    return head + "\n" + new_body


def write_sidecar(note, raw):
    # write-once pre-image, temp-and-rename: an interrupted copy leaves no truncated sidecar
    sidecar = note + ".pre-0013"
    if os.path.exists(sidecar):
        return
    d = os.path.dirname(note) or "."
    sfd, stmp = tempfile.mkstemp(dir=d, prefix=".pre-0013.", suffix=".tmp")
    try:
        with os.fdopen(sfd, "wb") as sfh:
            sfh.write(raw)
        os.replace(stmp, sidecar)
    except Exception:
        if os.path.exists(stmp):
            os.unlink(stmp)
        raise


def rewrite(note, raw, new_text):
    d = os.path.dirname(note) or "."
    write_sidecar(note, raw)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".0013.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(new_text.encode("utf-8", "surrogateescape"))
        os.chmod(tmp, stat.S_IMODE(os.stat(note).st_mode))
        os.replace(tmp, note)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def fail_line(verb, path, e):
    # one stderr line per failed path, as it happens: the path and the OS reason
    sys.stderr.write("0013: cannot %s %s: %s\n" % (verb, path, e.strerror or str(e)))


converted = 0
left = 0
failed = 0
try:
    names = sorted(os.listdir(inbox))
except OSError as e:
    fail_line("read", inbox, e)
    names = []
    failed += 1
for name in names:
    if name.startswith(("_", ".")) or not name.endswith(".md"):
        continue
    note = os.path.join(inbox, name)
    if os.path.islink(note) or not os.path.isfile(note):
        continue
    try:
        with open(note, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        fail_line("read", note, e)
        failed += 1
        continue
    text = raw.decode("utf-8", "surrogateescape")
    parts = split_note(text)
    if parts is None:
        continue
    lines, close = parts
    vals = first_values(lines[1:close])
    if unq(vals.get("type", "")) != "idea":
        continue
    if unq(vals.get("disposition", "")) != "DEFERRED":
        continue
    if any(unq(vals.get(k, "")) for k in TARGET_KEYS):
        sys.stderr.write("0013: left %s: carries absorbed_into, promoted_to or resolution\n" % name)
        left += 1
        continue
    try:
        rewrite(note, raw, convert(lines, close))
        converted += 1
    except OSError as e:
        fail_line("rewrite", note, e)
        failed += 1

if failed:
    sys.stderr.write("0013: deferred: %d note(s) could not be rewritten; re-run the upgrade\n" % failed)
    sys.exit(3)
sys.stderr.write(
    "0013: converged %d inbox note(s) from disposition DEFERRED to NO-BUILD, "
    "left %d carrying a target or a resolution\n" % (converted, left))
sys.exit(0)
PY
rc=$?
if [ "$rc" -eq 3 ]; then
  exit "${MIGRATION_DEFER_RC:-0}"
fi
exit "$rc"
