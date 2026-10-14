#!/bin/bash
# plan-asset — records a pointer row for a top-level plan-folder entry outside the managed set.
#
# The plan folder's managed set (governance/plans-rules.json :: plan_folder_managed_set) names the
# entries the plan tooling owns. Anything else at a plan's top level (a staged site, a scripts dir)
# carries one manifest assets[] row saying what it is for; placement-validate reports an entry of
# a non-terminal plan that has none as plan-unmanaged-entry, naming this verb.
#
#   plan-asset add <plan-dir> <path> --purpose "<text>"
#
# appends {path, purpose} to the manifest's assets[], or replaces the purpose of the row that
# already names <path>. One row per path.
#
# Refusals (exit 2, stderr reason, no write): a path that does not exist inside the plan dir
# (including one that escapes it, e.g. ../x), a path of more than one segment (a row names a
# top-level entry), a path in the managed set, an empty purpose, and a manifest that is missing,
# unreadable or carries a non-array assets.
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is cited only as
# the Output Contract's schema home (the manifest is read with plain json.load); no
# Draft202012Validator is constructed, so there is no schema-gate degrade path.
#
# Output Contract:
#   Files written: <plan-dir>/manifest.json (assets[] only; the rest re-serialized unchanged,
#     indent 2), atomic temp + os.replace in the plan dir.
#   stdout: one line `plan-asset: <plan-dir> <path> added|updated`.
#   Schema: schemas/plan-manifest-schema.json (assets[] item: required string path + purpose).
#   Pre-write validation: the refusals above. Any miss exits 2 and writes nothing.
#   Failure mode: block-and-log (exit 2, no write). Never write-and-hope.
#
# The managed set is read from the .plans slot of the merged foundation + overlay view
# (hooks/lib/foundation-overlay-load.sh), then the raw bundle, then the repo pillar;
# PLANS_RULES_PATH names a pillar file directly and wins.
#
# CLI:
#   plan-asset.sh add <plan-dir> <path> --purpose "<text>"
#   plan-asset.sh --help
#
# Bash 3.2 clean. Data reaches Python through argv, never a piped stdin.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

PURPOSE=""; HAVE_PURPOSE=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    --purpose) [ $# -ge 2 ] || { echo "plan-asset: --purpose needs a value" >&2; exit 2; }
               PURPOSE="$2"; HAVE_PURPOSE=1; shift 2 ;;
    -*)        echo "plan-asset: unknown flag '$1'" >&2; exit 2 ;;
    *)         ARGS+=("$1"); shift ;;
  esac
done
USAGE='plan-asset: usage: plan-asset add <plan-dir> <path> --purpose "<text>"'
[ "${#ARGS[@]}" -eq 3 ] && [ "${ARGS[0]}" = "add" ] || { echo "$USAGE" >&2; exit 2; }
[ "$HAVE_PURPOSE" = "1" ] || { echo "$USAGE" >&2; exit 2; }

PLAN_DIR="${ARGS[1]%/}"
[ -f "$PLAN_DIR/manifest.json" ] || { echo "plan-asset: no manifest.json in $PLAN_DIR; nothing written" >&2; exit 2; }

MANAGED=""
if [[ -n "${PLANS_RULES_PATH:-}" && -f "${PLANS_RULES_PATH}" ]]; then
  MANAGED=$(jq -c '(.plan_folder_managed_set // .plans.plan_folder_managed_set) // empty' "${PLANS_RULES_PATH}" 2>/dev/null || true)
fi
if [[ -z "$MANAGED" ]]; then
  _MASTER="${FOUNDATION_MASTER_PATH:-$CLAUDE_HOME_RES/governance/foundation-master.json}"
  if [[ -f "$_MASTER" ]]; then
    _OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
    [[ -x "$_OVL" ]] || _OVL="$_REPO_LIB/foundation-overlay-load.sh"
    if [[ -x "$_OVL" ]]; then
      # The loader's exit code and stderr are kept, never discarded: a failed or degraded overlay
      # load is named on stderr (one line, with its rc) before the raw-bundle fallback below.
      _OVL_ERR="$(mktemp -t plan-asset-ovl-XXXXXX)"; _OVL_RC=0
      _OVL_OUT=$(bash "$_OVL" --foundation-path "$_MASTER" \
          --overlay-path "$(dirname "$_MASTER")/overlay-master.json" --force-override 2>"$_OVL_ERR") || _OVL_RC=$?
      if [[ "$_OVL_RC" -ne 0 || -s "$_OVL_ERR" ]]; then
        echo "plan-asset: overlay load failed (rc $_OVL_RC): $(grep -v '^[[:space:]]*$' "$_OVL_ERR" | tail -1)" >&2
      fi
      rm -f "$_OVL_ERR"
      # swallow-ok: reports=none a loader failure is reported on stderr above; this jq only extracts one optional key from the output the loader just produced with exit 0, and an absent key reads as empty and falls back to the master read below
      [[ "$_OVL_RC" -eq 0 ]] && MANAGED=$(printf '%s' "$_OVL_OUT" \
          | jq -c '.plans.plan_folder_managed_set // empty' 2>/dev/null || true)
    fi
    [[ -z "$MANAGED" ]] && MANAGED=$(jq -c '.plans.plan_folder_managed_set // empty' "$_MASTER" 2>/dev/null || true)
  fi
fi
if [[ -z "$MANAGED" && -f "$_REPO_ROOT/governance/plans-rules.json" ]]; then
  MANAGED=$(jq -c '.plan_folder_managed_set // empty' "$_REPO_ROOT/governance/plans-rules.json" 2>/dev/null || true)
fi
[[ -n "$MANAGED" ]] || { echo "plan-asset: plan_folder_managed_set unreadable; nothing written" >&2; exit 2; }

python3 - "$PLAN_DIR" "${ARGS[2]}" "$PURPOSE" "$MANAGED" <<'PY'
import json, os, sys, tempfile

plan_dir, raw_path, purpose, managed_s = sys.argv[1:5]
mp = os.path.join(plan_dir, "manifest.json")


def refuse(msg):
    print("plan-asset: %s; nothing written" % msg, file=sys.stderr)
    sys.exit(2)


managed = set(json.loads(managed_s))
purpose = purpose.strip()
if not purpose:
    refuse("--purpose is empty")

root = os.path.realpath(plan_dir)
target = os.path.realpath(os.path.join(plan_dir, raw_path))
if target == root or not target.startswith(root + os.sep):
    refuse("'%s' is not inside %s" % (raw_path, plan_dir))
rel = os.path.relpath(target, root)
if os.sep in rel:
    refuse("'%s' is not a top-level entry of the plan dir (a row names one segment)" % raw_path)
if not os.path.lexists(os.path.join(root, rel)):
    refuse("'%s' does not exist in %s" % (raw_path, plan_dir))
if rel in managed:
    refuse("'%s' is in the managed set (plans-rules plan_folder_managed_set)" % rel)

try:
    with open(mp, encoding="utf-8") as fh:
        man = json.load(fh)
except Exception as exc:
    refuse("manifest unreadable (%s)" % exc)
assets = man.get("assets", [])
if not isinstance(assets, list):
    refuse("the manifest's assets is not an array")

verb = "added"
for row in assets:
    if isinstance(row, dict) and row.get("path") == rel:
        row["purpose"] = purpose
        verb = "updated"
        break
else:
    assets.append({"path": rel, "purpose": purpose})
man["assets"] = assets

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(mp)), prefix=".manifest.json.", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
    fh.write(json.dumps(man, indent=2, ensure_ascii=False) + "\n")
try:
    os.chmod(tmp, os.stat(mp).st_mode & 0o7777)
except OSError:
    pass
os.replace(tmp, mp)
print("plan-asset: %s %s %s" % (plan_dir, rel, verb))
PY
