#!/usr/bin/env bash
# skills/govern/lib/registry-add-spoke.sh — the one writer of anchored-spoke-registry.json.
#
#   registry-add-spoke.sh <registry> <spoke> <anchor> <description> <create|anchor>
#
# Appends {"spoke_key": <spoke>, "cwd_anchors": [<anchor>], "description": <description>}
# to the registry's spokes[]. Both registration paths of the project kind reach it through
# _proj_registry_add_spoke in modes/project.sh: the create and adopt commits (mode `create`)
# and the --anchor commit (mode `anchor`), so no registry write is unlocked.
#
# Mode `create` refuses an already-registered key. Mode `anchor` treats an entry with the
# same key and exactly the same single anchor as done: it prints a NOTE, writes nothing and
# exits 0, which lets a stopped registration be re-run to completion.
#
# An anchor is "claimed" when an entry of another spoke holds an equal anchor after a
# leading `~/` is expanded to `$HOME/` and the path is normalised (os.path.normpath) on both
# sides. A nested directory is not a claim: the longest anchor wins when a directory is
# resolved to its spoke.
#
# The script re-executes itself under `/usr/bin/lockf -k -t 0 <registry dir>/.anchored-spoke-registry.lock`
# (sentinel REGISTRY_ADD_SPOKE_LOCKED), reads the registry, refuses, appends and writes through
# `<registry>.tmp.<pid>` and one `mv -f`, all under the lock. A trap removes the temp file on every
# exit, a signal included.
#
# Exit codes: 0 written, or already registered for that anchor (anchor mode); 2 usage;
# 3 registry absent or unreadable; 4 key already registered, or anchor claimed; 5 lock held
# by another writer; 6 the atomic rename failed.
#
# bash 3.2 compatible.

set -u

USAGE_LINE='registry-add-spoke.sh: usage: registry-add-spoke.sh <registry> <spoke> <anchor> <description> <create|anchor>'

if [ "$#" -ne 5 ]; then
  printf '%s\n' "$USAGE_LINE" >&2
  exit 2
fi
REGISTRY="$1"
SPOKE="$2"
ANCHOR="$3"
DESCRIPTION="$4"
MODE="$5"
case "$MODE" in
  create|anchor) ;;
  *)
    printf '%s\n' "$USAGE_LINE" >&2
    exit 2
    ;;
esac
if [ -z "$REGISTRY" ] || [ -z "$SPOKE" ] || [ -z "$ANCHOR" ]; then
  printf '%s\n' "$USAGE_LINE" >&2
  exit 2
fi

if [ ! -r "$REGISTRY" ]; then
  printf 'project: registry not readable: %s\n' "$REGISTRY" >&2
  exit 3
fi

LOCK_FILE="$(dirname "$REGISTRY")/.anchored-spoke-registry.lock"

# ---- lock acquisition (re-exec under lockf) ----------------------------------
if [ -z "${REGISTRY_ADD_SPOKE_LOCKED:-}" ]; then
  export REGISTRY_ADD_SPOKE_LOCKED=1
  rc=0
  /usr/bin/lockf -k -t 0 "$LOCK_FILE" "$0" "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" = "75" ]; then
      printf 'registry-add-spoke.sh: lock contention on %s\n' "$LOCK_FILE" >&2
      exit 5
    fi
    exit "$rc"
  fi
  exit 0
fi

# ---- under the lock ----------------------------------------------------------
TMP="$REGISTRY.tmp.$$"
trap 'rm -f "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# python exits 0 with $TMP written, 10 when the spoke is already registered for this anchor
# (anchor mode; nothing to write), 3 or 4 on a refusal. Every value arrives through argv.
python3 - "$REGISTRY" "$SPOKE" "$ANCHOR" "$DESCRIPTION" "$MODE" "$TMP" <<'PY'
import json, os, sys

reg_path, spoke, anchor, description, mode, tmp = sys.argv[1:7]


def norm(path):
    if path.startswith("~/"):
        path = os.environ.get("HOME", "") + "/" + path[2:]
    return os.path.normpath(path)


try:
    with open(reg_path, encoding="utf-8") as fh:
        reg = json.load(fh)
    if not isinstance(reg, dict) or not isinstance(reg.get("spokes", []), list):
        raise ValueError("not an anchored-spoke registry object")
except Exception as exc:
    print("project: cannot read registry %s (%s)" % (reg_path, exc), file=sys.stderr)
    sys.exit(3)

spokes = reg.setdefault("spokes", [])
for sp in spokes:
    if sp.get("spoke_key", "") == spoke:
        if mode == "anchor" and sp.get("cwd_anchors") == [anchor]:
            print("project: NOTE — spoke '%s' is already registered for %s; registry left as is."
                  % (spoke, anchor), file=sys.stderr)
            sys.exit(10)
        print("project: spoke '%s' already registered — re-registration BLOCKED "
              "(no dup anchor, no re-scaffold)" % spoke, file=sys.stderr)
        sys.exit(4)

wanted = norm(anchor)
for sp in spokes:
    for raw in sp.get("cwd_anchors", []):
        if norm(raw) == wanted:
            print("project: anchor '%s' is already claimed by spoke '%s' — registration BLOCKED"
                  % (anchor, sp.get("spoke_key", "")), file=sys.stderr)
            sys.exit(4)

spokes.append({
    "spoke_key": spoke,
    "cwd_anchors": [anchor],
    "description": description,
})
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(reg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
sys.exit(0)
PY
rc=$?
if [ "$rc" = "10" ]; then
  exit 0
fi
if [ "$rc" != "0" ]; then
  exit "$rc"
fi
if ! mv -f "$TMP" "$REGISTRY"; then
  printf 'project: atomic registry rename failed: %s\n' "$REGISTRY" >&2
  exit 6
fi
exit 0
