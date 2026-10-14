#!/bin/bash
# plan-research-supersede — records that one declared research artifact supersedes another.
#
# A plan's manifest research_artifacts[] is the declared roster of its durable research. When a
# later artifact replaces an earlier one, this verb is the only writer of that relation:
#   1. the old entry: status -> superseded, superseded_by -> <new-RA>;
#   2. the new entry: supersedes -> <old-RA>;
#   3. the old file: one forward banner line inserted directly after its frontmatter
#        > Superseded by <new path> (<new-RA>) on <YYYY-MM-DD>.
#      (at the top of the file when it has no frontmatter). Every other byte is unchanged.
# The superseded file stays where it is; nothing is moved or deleted.
#
# Refusals (exit 2, stderr reason, no write): an RA id that is not ^RA-[0-9]+$, an RA the
# manifest does not declare, a self-supersession, an old entry already superseded, a cycle
# (following superseded_by from the new entry reaches the old one), and an old file that is
# missing or unreadable.
#
# plan-research-declare never writes these fields; library-scrub's PROMO-1 reads only
# status == "finalized", so a superseded entry is never a promotion candidate.
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is cited only as
# the Output Contract's schema home (the manifest is read with plain json.load); no
# Draft202012Validator is constructed, so there is no schema-gate degrade path.
#
# Output Contract:
#   Files written: <plan-dir>/manifest.json (the three fields above; the rest of the manifest
#     re-serialized unchanged, indent 2) and the old artifact file (the banner line). Each is
#     an atomic temp + os.replace in its own directory; both contents are built and validated
#     before either is replaced.
#   stdout: one line `plan-research-supersede: <plan-dir> <old-RA> -> <new-RA>`.
#   Schema: schemas/plan-manifest-schema.json (research_artifacts[] item: status enum
#     active|finalized|deferred|superseded; superseded_by / supersedes ^RA-[0-9]+$).
#   Pre-write validation: the refusals above. Any miss exits 2 and writes nothing.
#   Failure mode: block-and-log (exit 2, no write). Never write-and-hope.
#
# CLI:
#   plan-research-supersede.sh <plan-dir> <old-RA> <new-RA>
#   plan-research-supersede.sh --help
#
# Bash 3.2 clean. Data reaches Python through argv, never a piped stdin.

set -uo pipefail

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*)        echo "plan-research-supersede: unknown flag '$1'" >&2; exit 2 ;;
    *)         ARGS+=("$1"); shift ;;
  esac
done
[ "${#ARGS[@]}" -eq 3 ] || { echo "plan-research-supersede: usage: plan-research-supersede <plan-dir> <old-RA> <new-RA>" >&2; exit 2; }

PLAN_DIR="${ARGS[0]%/}"
[ -f "$PLAN_DIR/manifest.json" ] || { echo "plan-research-supersede: no manifest.json in $PLAN_DIR" >&2; exit 2; }

python3 - "$PLAN_DIR" "${ARGS[1]}" "${ARGS[2]}" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plan_dir, old_id, new_id = sys.argv[1:4]
mp = os.path.join(plan_dir, "manifest.json")


def refuse(msg):
    print("plan-research-supersede: %s; nothing written" % msg, file=sys.stderr)
    sys.exit(2)


RA_RE = re.compile(r"^RA-[0-9]+$")
for rid in (old_id, new_id):
    if not RA_RE.match(rid):
        refuse("'%s' is not an RA id (^RA-[0-9]+$)" % rid)
if old_id == new_id:
    refuse("%s cannot supersede itself" % old_id)

try:
    with open(mp, encoding="utf-8") as fh:
        man = json.load(fh)
except Exception as exc:
    refuse("manifest unreadable (%s)" % exc)
ras = man.get("research_artifacts")
if not isinstance(ras, list):
    refuse("the manifest declares no research_artifacts[]")
by_id = {}
for e in ras:
    if isinstance(e, dict) and isinstance(e.get("id"), str):
        by_id.setdefault(e["id"], e)
for rid in (old_id, new_id):
    if rid not in by_id:
        refuse("%s is not declared in research_artifacts[]" % rid)
old, new = by_id[old_id], by_id[new_id]
if old.get("status") == "superseded" or old.get("superseded_by"):
    refuse("%s is already superseded (by %s)" % (old_id, old.get("superseded_by") or "?"))

# A cycle: the superseded_by chain from the new entry reaches the old one.
seen, cur = set(), new
while isinstance(cur, dict) and cur.get("superseded_by") and cur["id"] not in seen:
    seen.add(cur["id"])
    nxt = cur["superseded_by"]
    if nxt == old_id:
        refuse("%s -> %s would close a cycle (%s is superseded along a chain ending at %s)"
               % (old_id, new_id, new_id, old_id))
    cur = by_id.get(nxt)


def resolve(p):
    return p if os.path.isabs(p) else os.path.join(plan_dir, p)


old_path = resolve(str(old.get("path") or ""))
new_rel = str(new.get("path") or "")
if not old.get("path") or not os.path.isfile(old_path):
    refuse("%s's file %s is missing" % (old_id, old_path))
try:
    with open(old_path, encoding="utf-8", newline="") as fh:
        text = fh.read()
except Exception as exc:
    refuse("%s's file is unreadable (%s)" % (old_id, exc))

banner = "> Superseded by %s (%s) on %s.\n" % (new_rel, new_id, date.today().isoformat())
lines = text.splitlines(True)
at = 0
if lines and lines[0].rstrip("\r\n") == "---":
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r\n") == "---":
            at = i + 1
            break
if at and not lines[at - 1].endswith("\n"):
    lines[at - 1] += "\n"
new_text = "".join(lines[:at]) + banner + "".join(lines[at:])

old["status"] = "superseded"
old["superseded_by"] = new_id
new["supersedes"] = old_id
man_text = json.dumps(man, indent=2, ensure_ascii=False) + "\n"


def stage(path, body):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
        fh.write(body)
    try:
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    except OSError:
        pass
    return tmp


try:
    t_file = stage(old_path, new_text)
    t_man = stage(mp, man_text)
except Exception as exc:
    refuse("staging failed (%s)" % exc)
os.replace(t_file, old_path)
os.replace(t_man, mp)
print("plan-research-supersede: %s %s -> %s" % (plan_dir, old_id, new_id))
PY
