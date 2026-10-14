#!/bin/bash
# memory-spill — relocates the coldest entries of the MEMORY.md index to MEMORY-archive.md.
#
# The harness loads only the first lines and bytes of MEMORY.md at session start, so an index
# that nears its cap pushes its bottom entries out of context. This command moves the coldest
# entries to an on-demand MEMORY-archive.md and leaves one pointer line in the index. Only the
# index lines move: every topic file stays where it is, and the readers that call a file
# missing from MEMORY.md an orphan also read the archive.
#
# Band: the larger of the effective line share (the larger of the raw line count and the
# comment-stripped line count, against max_lines) and the byte share (against max_bytes), as an
# integer percent, exactly as the memory consolidation runner's budget check computes it.
# GREEN is below YELLOW_PCT, YELLOW below RED_PCT, RED at or above it; the two thresholds are the
# runner's own, and a fixture holds them equal. A line longer than max_chars_per_line is a shape
# problem that relocating entries does not cure, so this command measures share alone. The caps
# come from the runner's own query of the governance bundle through foundation-overlay-load.sh;
# there are no fallback constants, so an unreadable bundle refuses.
#
# Plan: candidates are the lines beginning `- [` under `## Procedural`, then under
# `## Semantic`, taken tail-first (the coldest boundary of the fixed section order). Entries under
# `## Episodic` and an existing pointer line are never candidates, and neither is any other line.
# The plan is the shortest tail-first prefix whose removal, with the pointer line added, brings
# the index below YELLOW_PCT.
#
# Preview (the default) writes nothing and takes no lock. With --apply the command refuses at
# GREEN, when no prefix suffices and when MEMORY.md has no `## Semantic` heading to carry the
# pointer line; each of those is decided before the lock is taken. It then runs under one
# /usr/bin/lockf -k -t 2 on <memory dir>/.consolidation.lock, the runner's own lock, and under the
# lock it reads MEMORY.md again and recomputes the plan. The archive is written first, then
# MEMORY.md, each by temp file and `mv -f`. A stop between the two writes leaves a line in both
# files and loses none, and a rerun converges. With no /usr/bin/lockf the write runs unlocked.
#
# Derivations (what else must run when this capability writes a memory file): none. The
# memory-write hooks exclude the MEMORY.md index and skip a file with no frontmatter, which the
# archive is, so this command calls neither the memory-write hooks nor any post-write hook, and
# it opens no session-close step.
#
# Root: <root> is ${CLAUDE_HOME:-$HOME/.claude} when <root>/hooks/lib/foundation-overlay-load.sh is
# a regular file, otherwise the tree that holds this script (three directories above
# capabilities/). CLAUDE_HOME is exported as <root> for the loader call, so the loader reads that
# root's governance files and never an ambient CLAUDE_HOME that differs from it.
# FOUNDATION_MASTER_PATH and OVERLAY_MASTER_PATH pass through untouched.
#
# Output Contract:
#   Files written (--apply only):
#     - <memory dir>/MEMORY-archive.md  (begins `# Memory Archive`, one note sentence, then
#       `## Semantic` and `## Procedural`; each moved line is appended at the end of its section
#       in its original relative order, a line already present is skipped; written first)
#     - <memory dir>/MEMORY.md  (the moved lines gone, exactly one pointer line first under
#       `## Semantic`: `- [MEMORY-archive.md](memory/MEMORY-archive.md) — <N> colder entries,
#       read on demand`, N the archive's entry count; an existing pointer is replaced in place)
#     - <memory dir>/.consolidation.lock  (created by the lock call when absent)
#   stdout: `memory-spill: band=<GREEN|YELLOW|RED> pct=<n> lines=<a>/<max> bytes=<b>/<max>`, then
#     for a preview `memory-spill: would move <k> entries to MEMORY-archive.md; index pct <n> ->
#     <m>` and one `move`, tab, section, tab, entry line per entry (or `memory-spill: nothing to
#     move (GREEN)`); for an applied run only `memory-spill: moved <k> entries to
#     MEMORY-archive.md; index pct <n> -> <m>`.
#   stderr: every refusal is one line `memory-spill: refused: <why>`; a contended lock is
#     `memory-spill: lock contention on <lockfile> (rc 75); nothing was written`.
#   Exit codes: 0 done; 2 refused before anything was read (`--memory-dir needs a value`,
#     `no MEMORY.md in <dir>`, `unknown flag '<f>'`); 3 refused by the plan or a write
#     (`the index is GREEN (pct <n>); nothing to spill`, `moving every non-episodic entry would
#     not bring the index below YELLOW`, `cap config unavailable`, `MEMORY.md has no ## Semantic
#     section for the pointer line`, `could not replace <file> (rc <n>)`); 75 the lock is held.
#   Failure mode: block-and-log. Nothing is written once a refusal is decided; a failed replace
#     removes its temp files, and a failure on MEMORY.md leaves the archive written and MEMORY.md
#     byte-identical.
#
# CLI:
#   memory-spill.sh [--memory-dir DIR] [--apply]
#
# Environment: MEMORY_DIR pins the memory directory when --memory-dir is absent (the directory
# otherwise comes from resolve_memory_dir of hooks/lib/paths.sh).
#
# Bash 3.2 clean. Data reaches Python through argv, never a piped stdin.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
TREE="$(cd "$SELF_DIR/../../.." && pwd)"

YELLOW_PCT=75
RED_PCT=90
CAP_QUERY='.mandatory_files.mandates._memory_md_cap.thresholds'

refuse() { printf 'memory-spill: refused: %s\n' "$*" >&2; exit 2; }
fail3()  { printf 'memory-spill: refused: %s\n' "$*" >&2; exit 3; }

# --- arguments ---------------------------------------------------------------
MEM_DIR_ARG=""; HAVE_DIR=0; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --memory-dir)
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse "--memory-dir needs a value"; fi
      MEM_DIR_ARG="$2"; HAVE_DIR=1; shift 2 ;;
    *) refuse "unknown flag '$1'" ;;
  esac
done

# --- root and loader ---------------------------------------------------------
R=""
HOME_ROOT="${CLAUDE_HOME:-${HOME:-}/.claude}"
if [ -f "$HOME_ROOT/hooks/lib/foundation-overlay-load.sh" ]; then
  R="$HOME_ROOT"
elif [ -f "$TREE/hooks/lib/foundation-overlay-load.sh" ]; then
  R="$TREE"
fi
if [ -n "$R" ]; then
  export CLAUDE_HOME="$R"
fi

# --- memory directory --------------------------------------------------------
if [ "$HAVE_DIR" -eq 1 ]; then
  MEM_DIR="$MEM_DIR_ARG"
else
  PATHS_SH=""
  if [ -r "${R:-$TREE}/hooks/lib/paths.sh" ]; then
    PATHS_SH="${R:-$TREE}/hooks/lib/paths.sh"
  elif [ -r "$TREE/hooks/lib/paths.sh" ]; then
    PATHS_SH="$TREE/hooks/lib/paths.sh"
  fi
  MEM_DIR=""
  if [ -n "$PATHS_SH" ]; then
    # shellcheck disable=SC1090
    source "$PATHS_SH"
    MEM_DIR="$(resolve_memory_dir)"
  fi
  [ -n "$MEM_DIR" ] || refuse "--memory-dir needs a value"
fi
[ -f "$MEM_DIR/MEMORY.md" ] || refuse "no MEMORY.md in $MEM_DIR"

# --- caps --------------------------------------------------------------------
CAP_JSON=""
if [ -n "$R" ]; then
  if CAP_JSON="$(bash "$R/hooks/lib/foundation-overlay-load.sh" --force-override --query "$CAP_QUERY" 2>/dev/null)"; then
    :
  else
    CAP_JSON=""
  fi
fi

PYSRC='
import json, os, sys

mode, memdir, tmp_archive, tmp_index, cap_json, red_s, yellow_s = sys.argv[1:8]
RED = int(red_s)
YELLOW = int(yellow_s)
ARCHIVE = "MEMORY-archive.md"
DASH = "—"
NOTE = "Entries relocated from MEMORY.md by the memory-spill capability; each topic file stays in the memory directory and loads on demand."


def refuse(msg):
    sys.stdout.flush()
    sys.stderr.write("memory-spill: refused: %s\n" % msg)
    sys.exit(3)


def decode(raw):
    return raw.decode("utf-8", "surrogateescape")


def encode(text):
    return text.encode("utf-8", "surrogateescape")


def emit(line):
    sys.stdout.buffer.write(encode(line + "\n"))
    sys.stdout.buffer.flush()


def read_text(path):
    with open(path, "rb") as fh:
        return decode(fh.read())


try:
    caps = json.loads(cap_json)
    max_lines = caps["max_lines"]
    max_bytes = caps["max_bytes"]
except (ValueError, KeyError, TypeError):
    refuse("cap config unavailable")
for cap in (max_lines, max_bytes):
    if isinstance(cap, bool) or not isinstance(cap, int) or cap <= 0:
        refuse("cap config unavailable")


def split_lines(text):
    if text == "":
        return [], False
    nl = text.endswith("\n")
    parts = text.split("\n")
    if nl:
        parts.pop()
    return parts, nl


def join_lines(parts, nl):
    return "\n".join(parts) + ("\n" if nl and parts else "")


def measure(text):
    raw = text.count("\n")
    recs = text.split("\n")
    if recs and recs[-1] == "":
        recs.pop()
    inc = False
    kept = 0
    for rec in recs:
        if "<!--" in rec:
            inc = True
        if not inc:
            kept += 1
        if "-->" in rec:
            inc = False
    eff = max(raw, kept)
    nbytes = len(encode(text))
    pct = max(eff * 100 // max_lines, nbytes * 100 // max_bytes)
    return eff, nbytes, pct


def band_of(pct):
    if pct >= RED:
        return "RED"
    if pct >= YELLOW:
        return "YELLOW"
    return "GREEN"


def is_ptr(line):
    return line.startswith("- [" + ARCHIVE + "]")


def sem_index(parts):
    for i, ln in enumerate(parts):
        if ln.rstrip() == "## Semantic":
            return i
    return None


def candidates(parts):
    sec = ""
    found = []
    for i, ln in enumerate(parts):
        if ln.startswith("## "):
            sec = ln.rstrip()
        elif sec in ("## Procedural", "## Semantic") and ln.startswith("- [") and not is_ptr(ln):
            found.append((sec[3:], i))
    proc = [c for c in found if c[0] == "Procedural"]
    sem = [c for c in found if c[0] == "Semantic"]
    return proc[::-1] + sem[::-1]


def insert_into(parts, section, new):
    heading = "## " + section
    h = None
    for i, ln in enumerate(parts):
        if ln.rstrip() == heading:
            h = i
            break
    if h is None:
        if parts and parts[-1] != "":
            parts.append("")
        parts.append(heading)
        parts.append("")
        parts.extend(new)
        return
    e = len(parts)
    for j in range(h + 1, len(parts)):
        if parts[j].startswith("## "):
            e = j
            break
    last = h
    for j in range(h + 1, e):
        if parts[j].strip() != "":
            last = j
    if last > h:
        parts[last + 1:last + 1] = new
        return
    at = h + 1
    block = list(new)
    if at < e and parts[at].strip() == "":
        at += 1
    else:
        block = [""] + block
    if at < len(parts) and parts[at].startswith("## "):
        block = block + [""]
    parts[at:at] = block


index_path = os.path.join(memdir, "MEMORY.md")
archive_path = os.path.join(memdir, ARCHIVE)
text = read_text(index_path)
lines, had_nl = split_lines(text)
if os.path.isfile(archive_path):
    a_exists = True
    a_lines, a_nl = split_lines(read_text(archive_path))
else:
    a_exists = False
    a_lines, a_nl = [], True

eff, nbytes, pct = measure(text)
band = band_of(pct)
if mode == "preview":
    emit("memory-spill: band=%s pct=%d lines=%d/%d bytes=%d/%d" % (band, pct, eff, max_lines, nbytes, max_bytes))
    if band == "GREEN":
        emit("memory-spill: nothing to move (GREEN)")
        sys.exit(0)
elif band == "GREEN":
    refuse("the index is GREEN (pct %d); nothing to spill" % pct)

if sem_index(lines) is None:
    refuse("MEMORY.md has no ## Semantic section for the pointer line")

CANDS = candidates(lines)


def build(k):
    moved = CANDS[:k]
    drop = set(i for _, i in moved)
    per = {"Semantic": [], "Procedural": []}
    for sec, i in sorted(moved, key=lambda c: c[1]):
        per[sec].append(lines[i])
    present = set(ln for ln in a_lines if ln.startswith("- ["))
    added = {"Semantic": [], "Procedural": []}
    for sec in ("Semantic", "Procedural"):
        for ln in per[sec]:
            if ln not in present:
                added[sec].append(ln)
                present.add(ln)
    n_total = sum(1 for ln in a_lines if ln.startswith("- [")) + len(added["Semantic"]) + len(added["Procedural"])
    if a_exists:
        out_a = list(a_lines)
        for sec in ("Semantic", "Procedural"):
            if added[sec]:
                insert_into(out_a, sec, added[sec])
        a_out = join_lines(out_a, a_nl)
    else:
        out_a = ["# Memory Archive", "", NOTE, ""]
        for sec in ("Semantic", "Procedural"):
            out_a.append("## " + sec)
            if added[sec]:
                out_a.append("")
                out_a.extend(added[sec])
            out_a.append("")
        while out_a and out_a[-1] == "":
            out_a.pop()
        a_out = join_lines(out_a, True)
    kept = [ln for i, ln in enumerate(lines) if i not in drop]
    ptr = "- [%s](memory/%s) %s %d colder entries, read on demand" % (ARCHIVE, ARCHIVE, DASH, n_total)
    where = [i for i, ln in enumerate(kept) if is_ptr(ln)]
    if where:
        kept[where[0]] = ptr
        for i in reversed(where[1:]):
            del kept[i]
    else:
        s = sem_index(kept)
        pos = None
        j = s + 1
        while j < len(kept) and not kept[j].startswith("## "):
            if kept[j].startswith("- ["):
                pos = j
                break
            j += 1
        if pos is None:
            pos = s + 1
            while pos < len(kept) and kept[pos].strip() == "":
                pos += 1
            kept.insert(pos, ptr)
            if pos + 1 < len(kept) and kept[pos + 1].startswith("## "):
                kept.insert(pos + 1, "")
        else:
            kept.insert(pos, ptr)
    i_out = join_lines(kept, had_nl)
    return {"k": k, "moved": moved, "a_out": a_out, "i_out": i_out, "pct": measure(i_out)[2]}


plan = None
for k in range(1, len(CANDS) + 1):
    trial = build(k)
    if trial["pct"] < YELLOW:
        plan = trial
        break
if plan is None:
    refuse("moving every non-episodic entry would not bring the index below YELLOW")

if mode == "preview":
    emit("memory-spill: would move %d entries to MEMORY-archive.md; index pct %d -> %d" % (plan["k"], pct, plan["pct"]))
    for sec, i in plan["moved"]:
        emit("move\t%s\t%s" % (sec, lines[i]))
    sys.exit(0)
if mode == "check":
    sys.exit(0)

try:
    index_mode = os.stat(index_path).st_mode & 0o7777
    with open(tmp_archive, "wb") as fh:
        fh.write(encode(plan["a_out"]))
    with open(tmp_index, "wb") as fh:
        fh.write(encode(plan["i_out"]))
    os.chmod(tmp_index, index_mode)
except OSError:
    for leftover in (tmp_archive, tmp_index):
        if os.path.exists(leftover):
            os.remove(leftover)
    refuse("could not replace MEMORY-archive.md (rc 1)")
emit("memory-spill: moved %d entries to MEMORY-archive.md; index pct %d -> %d" % (plan["k"], pct, plan["pct"]))
'

run_py() { # run_py <mode> [<temp archive> <temp index>]
  python3 -c "$PYSRC" "$1" "$MEM_DIR" "${2:-}" "${3:-}" "$CAP_JSON" "$RED_PCT" "$YELLOW_PCT"
}

# --- preview -----------------------------------------------------------------
if [ "$APPLY" -eq 0 ]; then
  run_py preview
  exit $?
fi

# --- apply: every refusal is decided before the lock -------------------------
if [ -z "${MEMORY_SPILL_LOCKED:-}" ]; then
  run_py check || exit $?
  if [ -x /usr/bin/lockf ]; then
    LOCKFILE="$MEM_DIR/.consolidation.lock"
    rc=0
    MEMORY_SPILL_LOCKED=1 /usr/bin/lockf -k -t 2 "$LOCKFILE" "${BASH:-bash}" "$SELF" --memory-dir "$MEM_DIR" --apply || rc=$?
    if [ "$rc" -eq 75 ]; then
      printf 'memory-spill: lock contention on %s (rc 75); nothing was written\n' "$LOCKFILE" >&2
    fi
    exit "$rc"
  fi
fi

# --- apply: under the lock, recompute from the file as it is now --------------
TMP_ARCHIVE="$MEM_DIR/.MEMORY-archive.md.spill-tmp"
TMP_INDEX="$MEM_DIR/.MEMORY.md.spill-tmp"
rc=0
SUMMARY="$(run_py apply "$TMP_ARCHIVE" "$TMP_INDEX")" || rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

mv -f "$TMP_ARCHIVE" "$MEM_DIR/MEMORY-archive.md" || rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$TMP_ARCHIVE" "$TMP_INDEX"
  fail3 "could not replace MEMORY-archive.md (rc $rc)"
fi
mv -f "$TMP_INDEX" "$MEM_DIR/MEMORY.md" || rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$TMP_INDEX"
  fail3 "could not replace MEMORY.md (rc $rc)"
fi
printf '%s\n' "$SUMMARY"
exit 0
