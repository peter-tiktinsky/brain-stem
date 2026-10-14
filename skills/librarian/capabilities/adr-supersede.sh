#!/bin/bash
# adr-supersede — records that one accepted ADR is superseded by another.
#
# An accepted ADR is an immutable record (governance/file-type-contracts/adr.md.json ::
# immutable_post_accepted): its body above the first amendment heading is never edited in place.
# When a later decision replaces it, this verb is the only writer of that relation:
#   1. the old ADR's body `**Status:**` line becomes `**Status:** superseded-by-<new-ADR>`;
#   2. the old ADR's frontmatter `status:` becomes `superseded` (when the frontmatter has one);
#   3. the plan manifest's decision_records[] entry for the old ADR gets `status: superseded`
#      and `superseded_by: <new-ADR>`.
# Nothing else changes. The new ADR is not touched: it is written first, with the plan-rule
# --spec-change verb, and this verb then links the pair. The superseded file stays where it is.
#
# Refusals (exit 2, one reason line on stderr, nothing written): an ADR id that is not
# ^ADR-[0-9]{2,}$, old and new the same id, a manifest.json that is missing or does not parse,
# an old or new ADR file under <plan-dir>/decisions/ that is missing or ambiguous (two files for
# one id), an old ADR whose body Status is not `accepted`, and an old id with no decision_records[]
# entry.
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is cited only as
# the Output Contract's schema home (the manifest is read with plain json.load); no schema
# validator is constructed, so there is no schema-gate degrade path.
#
# Output Contract:
#   Files written: the old ADR file (the Status line and the frontmatter status) and
#     <plan-dir>/manifest.json (the one entry's two fields; the rest of the manifest
#     re-serialized unchanged, indent 2). Each is an atomic temp + os.replace in its own
#     directory; both contents are built and validated before either is replaced.
#   stdout: one line `adr-supersede: <plan-dir> <old-ADR> -> <new-ADR>`.
#   Schema: schemas/plan-manifest-schema.json (decision_records[] item: status enum
#     proposed|accepted|rejected|deprecated|superseded; id ^ADR-[0-9]{2,}$; superseded_by).
#   Pre-write validation: the refusals above. Any miss exits 2 and writes nothing.
#   Failure mode: block-and-log (exit 2, no write). Never write-and-hope.
#
# CLI:
#   adr-supersede.sh <plan-dir> <old-ADR> <new-ADR>
#   adr-supersede.sh --help
#
# Bash 3.2 clean. Data reaches Python through argv, never a piped stdin.

set -uo pipefail

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*)        echo "adr-supersede: unknown flag '$1'" >&2; exit 2 ;;
    *)         ARGS+=("$1"); shift ;;
  esac
done
[ "${#ARGS[@]}" -eq 3 ] || { echo "adr-supersede: usage: adr-supersede.sh <plan-dir> <old-ADR> <new-ADR>" >&2; exit 2; }

PLAN_DIR="${ARGS[0]%/}"

python3 - "$PLAN_DIR" "${ARGS[1]}" "${ARGS[2]}" <<'PY'
import glob, json, os, re, sys, tempfile

plan_dir, old_id, new_id = sys.argv[1:4]
mp = os.path.join(plan_dir, "manifest.json")


def refuse(msg):
    print("adr-supersede: %s; nothing written" % msg, file=sys.stderr)
    sys.exit(2)


ID_RE = re.compile(r"^ADR-[0-9]{2,}$")
for aid in (old_id, new_id):
    if not ID_RE.match(aid):
        refuse("'%s' is not an ADR id (^ADR-[0-9]{2,}$)" % aid)
if old_id == new_id:
    refuse("%s cannot supersede itself" % old_id)

try:
    with open(mp, encoding="utf-8") as fh:
        man = json.load(fh)
except Exception as exc:
    refuse("%s is missing or unparseable (%s)" % (mp, exc))
if not isinstance(man, dict):
    refuse("%s is not a JSON object" % mp)

files = {}
for aid in (old_id, new_id):
    hits = sorted(glob.glob(os.path.join(glob.escape(plan_dir), "decisions", glob.escape(aid) + "-*.md")))
    if len(hits) != 1:
        refuse("%s has %d files under %s/decisions/ (want exactly 1)" % (aid, len(hits), plan_dir))
    files[aid] = hits[0]
old_path = files[old_id]

records = man.get("decision_records")
entry = None
if isinstance(records, list):
    for rec in records:
        if isinstance(rec, dict) and rec.get("id") == old_id:
            entry = rec
            break
if entry is None:
    refuse("%s has no decision_records[] entry in %s" % (old_id, mp))

try:
    with open(old_path, encoding="utf-8", newline="") as fh:
        text = fh.read()
except Exception as exc:
    refuse("%s is unreadable (%s)" % (old_path, exc))

lines = text.splitlines(True)
body_at = 0
fm_end = 0
if lines and lines[0].rstrip("\r\n") == "---":
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r\n") == "---":
            fm_end = i
            body_at = i + 1
            break

status_re = re.compile(r"^\*\*Status:\*\*\s*(.*?)\s*$")
status_at = None
for i in range(body_at, len(lines)):
    m = status_re.match(lines[i].rstrip("\r\n"))
    if m:
        status_at = i
        status_val = m.group(1)
        break
if status_at is None:
    refuse("%s carries no body **Status:** line" % old_path)
if status_val != "accepted":
    refuse("%s body Status is '%s', not 'accepted'" % (old_id, status_val))


def eol_of(line):
    return line[len(line.rstrip("\r\n")):]


lines[status_at] = "**Status:** superseded-by-%s%s" % (new_id, eol_of(lines[status_at]))
if fm_end:
    for i in range(1, fm_end):
        if re.match(r"^status:", lines[i]):
            lines[i] = "status: superseded%s" % eol_of(lines[i])
            break
new_text = "".join(lines)

entry["status"] = "superseded"
entry["superseded_by"] = new_id
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
print("adr-supersede: %s %s -> %s" % (plan_dir, old_id, new_id))
PY
