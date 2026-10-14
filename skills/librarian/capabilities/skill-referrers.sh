#!/bin/bash
# skill-referrers — lists the files that reference a skill by name.
#
# After a skill changes, every skill, hook, governance file, template, schema, rule and
# settings entry that names it may need the same change. This command prints that list, so the
# post-change grep for downstream references is one command:
#   skill-referrers.sh <skill-name> [--root DIR]...
#
# The name must match ^[a-z0-9][a-z0-9-]*$. The default root is the tree that holds this script
# (three directories above capabilities/); each --root replaces the default and may repeat. Under
# each root it scans skills, hooks, governance, templates, schemas and rules, plus the file
# settings.json, for the name as a token (not preceded or followed by a letter, a digit, an
# underscore or a hyphen). It skips skills/<name>/ itself, any _archive or baselines directory,
# and any binary file.
#
# Read-only: it writes no file and calls no hook, so no tool-event or session-close derivation
# applies.
#
# Output Contract:
#   Files written: none.
#   stdout: `skill-referrers: <name>: <k> file(s)`, then one line per referring file: the root as
#     passed (a trailing slash dropped) joined to the file's relative path, a tab, and the count
#     of matching LINES (a line naming the skill twice counts once). Rows are sorted by code point
#     of that path, never by the ambient locale. Zero referrers prints the header alone, exit 0.
#   Pre-write validation: none (nothing is written). Refusals exit 2 with one stderr line:
#     `skill-referrers: refused: no skill name`
#     `skill-referrers: refused: skill name '<x>' is not a plain skill name`
#     `skill-referrers: refused: no skill '<name>' under any root`
#     `skill-referrers: refused: --root needs a value`
#     `skill-referrers: refused: unknown flag '<f>'`
#     `skill-referrers: refused: one skill name only`
#   Failure mode: block-and-log (exit 2, no output on stdout).
#
# CLI:
#   skill-referrers.sh <skill-name> [--root DIR]...
#   skill-referrers.sh --help
#
# Bash 3.2 clean. Data reaches Python through argv, never a piped stdin.

set -uo pipefail

refuse() { echo "skill-referrers: refused: $1" >&2; exit 2; }

NAME=""; HAVE_NAME=0; ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    --root)
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse "--root needs a value"; fi
      ROOTS+=("$2"); shift 2 ;;
    -*) refuse "unknown flag '$1'" ;;
    *)
      [ "$HAVE_NAME" -eq 0 ] || refuse "one skill name only"
      NAME="$1"; HAVE_NAME=1; shift ;;
  esac
done

if [ "${#ROOTS[@]}" -eq 0 ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOTS=("$(cd "$HERE/../../.." && pwd)")
fi

python3 - "$HAVE_NAME" "$NAME" "${ROOTS[@]}" <<'PY'
import os, re, sys

have_name, name = sys.argv[1], sys.argv[2]
roots = [r.rstrip("/") if r.rstrip("/") else "/" for r in sys.argv[3:]]


def refuse(msg):
    sys.stderr.write("skill-referrers: refused: %s\n" % msg)
    sys.exit(2)


if have_name != "1":
    refuse("no skill name")
if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name, re.ASCII):
    refuse("skill name '%s' is not a plain skill name" % name)


def join(root, rel):
    return (root + rel) if root == "/" else (root + "/" + rel)


if not any(os.path.isdir(join(r, "skills/" + name)) for r in roots):
    refuse("no skill '%s' under any root" % name)

TOKEN = re.compile(rb"(?<![A-Za-z0-9_-])" + re.escape(name.encode("ascii")) + rb"(?![A-Za-z0-9_-])")
SCAN_DIRS = ("skills", "hooks", "governance", "templates", "schemas", "rules")
SKIP_DIRS = ("_archive", "baselines")
self_rel = "skills/" + name

rows = {}


def count_file(path):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return 0
    if b"\0" in data:
        return 0
    return sum(1 for line in data.split(b"\n") if TOKEN.search(line))


for root in roots:
    for top in SCAN_DIRS:
        base = join(root, top)
        if not os.path.isdir(base):
            continue
        for cur, dirs, files in os.walk(base):
            rel_cur = os.path.relpath(cur, root)
            dirs[:] = [d for d in dirs
                       if d not in SKIP_DIRS and os.path.join(rel_cur, d) != self_rel]
            for fn in files:
                full = os.path.join(cur, fn)
                if not os.path.isfile(full):
                    continue
                n = count_file(full)
                if n:
                    rows[join(root, os.path.relpath(full, root))] = n
    settings = join(root, "settings.json")
    if os.path.isfile(settings):
        n = count_file(settings)
        if n:
            rows[settings] = n

out = ["skill-referrers: %s: %d file(s)" % (name, len(rows))]
for path in sorted(rows):
    out.append("%s\t%d" % (path, rows[path]))
sys.stdout.buffer.write(os.fsencode("\n".join(out) + "\n"))
PY
