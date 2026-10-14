#!/bin/bash
# field-set.sh — set one field of a brain-stem record from the command line: validated against
# the record's source of truth, written atomically, and never leaving a half-written file.
#
# USAGE
#   field-set.sh user-manifest set <dotted.key> <value> [--manifest PATH]
#   field-set.sh settings hook off|on <hook-basename> [--settings PATH]
#   field-set.sh settings env set <KEY> <value> [--settings PATH]
#   field-set.sh plan set <manifest.json> [status=<status>] [paused_reason=<reason>] [disposition=<d>]
#   field-set.sh capture-freeze open|lift <spoke> [--plans-root DIR]
#   field-set.sh --help
#
# PROFILES. The first argument names a profile. Each profile is an in-script function behind
# the dispatch table in main(); a new flow adds a profile, not a file. A profile this script
# does not carry exits 2 with `field-set: unknown profile '<name>'`, decided before any file is
# read.
#
#   user-manifest set <dotted.key> <value>
#     Sets one scalar leaf of user-manifest.json (default
#     ${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}; --manifest PATH
#     overrides). The manifest must already exist: the setter never creates it. The key must be
#     reachable through the `properties` declared in
#     ${CLAUDE_HOME:-$HOME/.claude}/schemas/user-manifest-schema.json, so a typo never writes a
#     dead key. The value is coerced by the leaf type (string, boolean, integer, number) and an
#     enum leaf takes one of its members. No tool-event derivation is bound to the user
#     manifest (no hooks/post-*.sh names it), so none runs after the write.
#
#   settings hook off|on <hook-basename>
#     Turns a hook off or back on in ${CLAUDE_HOME:-$HOME/.claude}/settings.json. `off` removes
#     every entry under `.hooks` whose command is the basename or ends in /<basename>, in every
#     event and each of several in one group, and records event, group index, entry index and
#     the entry in $HOOKS_STATE/field-set-hook-off/<basename>.json (a JSON array, one record per
#     removed entry); a group its removal empties is removed with the entry (the record carries
#     the group), and an event key left with no group is removed too (the record carries the key's
#     position among the `.hooks` keys). `on` puts each entry back at its recorded position,
#     recreates an absent event key at its recorded position, and deletes the record; an entry
#     whose command is already under that event (the installer re-landed it) is skipped with a
#     `NOTE: <basename> already present under <event>; not restored twice` line. A
#     jq-canonical settings.json round-trips byte-identically; any other file round-trips equal
#     under `jq -S` after one whitespace normalization. A second `off` with no entry left but a
#     record present exits 0 `field-set: <basename> already off`; `off` with neither refuses, and
#     `on` with no record refuses. `off` also refuses (exit 3) a call that would leave the file
#     with no `memory-consolidation-check.sh` or `claude-mem` entry, the pre-write guard's R-24
#     rule, unless CLAUDE_MEM_DISABLE_OK=1, which appends one `| field-set | CLAUDE_MEM_DISABLE_OK
#     override |` line to ${CLAUDE_STATE_ROOT}/audit/hook-audit.log. The rule binds `off` only. A
#     hook listed in ${CLAUDE_HOME:-$HOME/.claude}/templates/settings-required-hooks.json prints a
#     `NOTE:` on stderr, because the installer re-lands a required hook on the next upgrade.
#     --settings PATH replaces that file; one record per basename, so `on` restores into its own --settings file.
#
#   settings env set <KEY> <value>
#     Writes .env.<KEY> in the same settings.json. KEY is upper-case letters, digits and
#     underscores, starting with a letter.
#
#   No tool-event derivation is bound to settings.json (no hooks/post-*.sh names it), so none
#   runs after a settings write; the R-24 rule above lives here because the pre-write guard never
#   sees a script's write.
#
#   plan set <manifest.json> [status=<status>] [paused_reason=<reason>] [disposition=<d>]
#     Moves one plan manifest to its next status. The settable fields are status, paused_reason
#     and disposition; any other field is refused. disposition must be a member of
#     ${CLAUDE_HOME:-$HOME/.claude}/schemas/plan-manifest-schema.json :: disposition.enum (which
#     mirrors governance/plans-rules.json :: backlog_row.disposition_enum); it is written in the
#     same atomic write as status and updated (`status=planned disposition=<d>` is step 9 of
#     backlog-research), and a call with disposition only is allowed: the edge check and the close
#     rules read a `status` field only. The setter never runs backlog-index and never writes
#     _backlog.md, which stays librarian-owned. The edge must be one of lifecycle.transitions,
#     read from the rules chain (PLANS_RULES_PATH, then ${CLAUDE_HOME:-$HOME/.claude}/governance/
#     plans-rules.json, then foundation-overlay-load.sh --query '.plans' --force-override): researching
#     to planned, planned to in-progress, in-progress to and from paused, in-progress to completed;
#     superseded has no edge and is refused. paused takes a paused_reason from the plan-manifest
#     schema enum and any other status refuses one; a resume (paused to in-progress) deletes it, and
#     every other write leaves a seeded value alone. Every write stamps `updated` (honoring
#     SESSION_CLOSE_TODAY). A write of `completed` applies the session-close rules, in this order and
#     with no step writing before the next has passed: the ordering gate (a terminal status over a
#     task row that is not advanced is refused, exit 3), then
#     skills/librarian/capabilities/plan-research-declare.sh --spoke <project> (declare, then
#     stamp; a missing or failing declare refuses, exit 2), then one atomic write of status,
#     completed_at (never overwritten), research_closed and updated from a re-read of the manifest,
#     so what the declare appended to research_artifacts[] is kept. The declare is spoke-wide, as
#     in session-close; this write touches only the named manifest. After a successful write the
#     setter fires the derivations a tool-event write of the manifest would have: it runs
#     ${CLAUDE_HOME:-$HOME/.claude}/hooks/post-manifest-binder-refresh.sh on the manifest (the
#     binder and tasks.md re-render) and hooks/post-tool-use-manifest.sh with a PostToolUse payload
#     (the manifest verify, and the library-promotion queue for a plan that reached completed), each
#     failing open with a `NOTE:` when the hook is missing. After a write whose resulting status is
#     terminal, and only then, it runs plan-terminal-lag-check.sh and prints one `LAG: plan_slug=<s>
#     plan_status=<s> parent_plan=<p> parent_status=<s>` line per sub-plan that lags under the
#     written plan, the capability's own parent resolution deciding which plan a finding belongs to.
#     Nothing is written to a sub-plan: walking the lagging subs stays the operator's call.
#
#   capture-freeze open|lift <spoke> [--plans-root DIR]
#     Opens or lifts a spoke's capture freeze. `open` writes the record named by
#     inbox.capture_freeze_record in the plans rules (_projects/<spoke>/.capture-freeze) as exactly
#     one line `start_sha=<40-hex>`, the plans repository's HEAD; `lift` removes it, and lifting with
#     no record in force is a no-op that says so. The plans root is --plans-root, else a non-empty
#     PLANS_ROOT, else PLANS_DIR as paths.sh resolves it, the chain backlog-index.sh reads the record
#     through. `open` refuses, nothing written and in this order: a plans root that is not the top
#     level of a git repository (the test backlog-index.sh applies), a spoke that is not a plain key,
#     a spoke with no _projects/<spoke> directory (these three exit 2), and a freeze already open
#     (exit 3). No tool-event derivation is bound to the record; backlog-index --freeze-check reads it.
#
# EXIT CODES. 0 done or a documented no-op. 2 refused: bad input, validation or precondition;
# nothing is written and the target's bytes are unchanged. 3 refused by a governance gate. 75
# lock contention. Every refusal line starts `field-set: refused:`.
#
# THE LOCK. Every write runs as one re-exec of this script under /usr/bin/lockf -k -t 2 on
# $HOOKS_STATE/field-set.lock (kernel-backed, the lock idiom of hooks/lib/execution-queue.sh),
# so two concurrent callers can no longer clobber each other's field. The re-exec is taken after
# the dispatch table has resolved the profile and wraps only that profile's path: an unknown
# profile exits 2 under a held lock, never 75. FIELD_SET_LOCKED marks the locked child. Contention
# is loud, never a silent skip: exit 75 with `field-set: lock contention on <lockfile> (rc 75);
# nothing was written`. Only rc 75 is contention; any other child rc passes through unchanged. With
# /usr/bin/lockf absent the write runs unlocked and silent, as execution-queue.sh does.
#
# WRITE DISCIPLINE. JSON edits go through jq (setpath). The whole target is parsed before any
# write; the result is written to a temp file in the target's own directory, parsed again, then
# renamed over the target. No temp file survives any exit: a trap on EXIT, INT, TERM and HUP
# removes it. A refusal happens before the write, so a refused call leaves the target
# byte-identical.
#
# VALIDATION TIERS (leaf only; the root document is never validated, so a pre-existing
# violation the setter did not cause cannot block a write). (1) A stdlib leaf type and enum
# check against the declared schema leaf, always. (2) jsonschema validation of the leaf value
# when jsonschema is importable. (3) A key not reachable through declared `properties` is
# refused.
#
# SIBLINGS resolve through paths.sh beside this script (never from $CLAUDE_HOME), as the other
# shipped CLIs in this directory do. JSON data reaches python through argv, never a piped
# stdin. Bash 3.2 clean per R-23.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/paths.sh" 2>/dev/null || true
set -u

FS_SELF="$SCRIPT_DIR/$(basename "$0")"
FS_PROFILE=""
FS_TMP=""
FS_TMP2=""
FS_SIDECAR_NEW=""
FS_LAGOUT=""
FS_SETTINGS=""

fs_usage() {
  printf 'usage: field-set.sh user-manifest set <dotted.key> <value> [--manifest PATH]\n'
  printf '       field-set.sh settings hook off|on <hook-basename> [--settings PATH]\n'
  printf '       field-set.sh settings env set <KEY> <value> [--settings PATH]\n'
  printf '       field-set.sh plan set <manifest.json> [status=<status>] [paused_reason=<reason>] [disposition=<d>]\n'
  printf '       field-set.sh capture-freeze open|lift <spoke> [--plans-root DIR]\n'
  printf '       field-set.sh --help\n'
  printf 'exit: 0 done or no-op; 2 refused (nothing written); 3 refused by a governance gate; 75 lock contention\n'
}

# fs_refuse <message>: the one refusal exit. Prints `field-set: refused: <message>` and exits 2.
fs_refuse() {
  printf 'field-set: refused: %s\n' "$*" >&2
  exit 2
}

fs_cleanup() {
  if [ -n "$FS_TMP" ]; then rm -f "$FS_TMP"; fi
  FS_TMP=""
  if [ -n "$FS_TMP2" ]; then rm -f "$FS_TMP2"; fi
  FS_TMP2=""
  if [ -n "$FS_SIDECAR_NEW" ]; then rm -f "$FS_SIDECAR_NEW"; fi
  FS_SIDECAR_NEW=""
  if [ -n "$FS_LAGOUT" ]; then rm -f "$FS_LAGOUT"; fi
  FS_LAGOUT=""
}

fs_install_traps() {
  trap fs_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

fs_need_tools() {
  command -v jq >/dev/null 2>&1 || fs_refuse "jq is required"
  command -v python3 >/dev/null 2>&1 || fs_refuse "python3 is required"
}

# fs_jq_write <target> <jq args...>: parse the target, apply the jq program, parse the result,
# then rename it over the target. The temp file lives in the target's own directory and keeps
# the target's mode.
fs_jq_write() {
  local target="$1" dir err rc
  shift
  dir="$(dirname "$target")"
  jq -e 'type == "object"' "$target" >/dev/null 2>&1 || fs_refuse "$target is not a JSON object"
  FS_TMP="$(mktemp "$dir/.field-set.XXXXXX")" || fs_refuse "cannot create a temp file beside $target"
  cp -p "$target" "$FS_TMP" || fs_refuse "cannot copy the mode of $target to its temp file"
  err="$(jq "$@" "$target" 2>&1 >"$FS_TMP")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fs_cleanup
    fs_refuse "jq could not apply the edit to $target (rc $rc): $err"
  fi
  if ! jq -e 'type == "object"' "$FS_TMP" >/dev/null 2>&1; then
    fs_cleanup
    fs_refuse "the edited document for $target does not parse"
  fi
  if ! mv -f "$FS_TMP" "$target"; then
    fs_cleanup
    fs_refuse "could not replace $target"
  fi
  FS_TMP=""
}

# Leaf resolution and validation, run through python3 with the data on argv. Prints two lines
# on success: the key path as a JSON array, then the coerced value as JSON. A refusal prints its
# own `field-set: refused:` line on stderr and exits 2.
IFS= read -r -d '' FS_PY_LEAF <<'PY'
import json
import re
import sys

schema_path, dotted, raw = sys.argv[1], sys.argv[2], sys.argv[3]


def refuse(msg):
    sys.stderr.write("field-set: refused: %s\n" % msg)
    sys.exit(2)


try:
    with open(schema_path) as fh:
        node = json.load(fh)
except (OSError, ValueError) as exc:
    refuse("cannot read the schema %s (%s)" % (schema_path, exc))

segs = dotted.split(".")
if any(seg == "" for seg in segs):
    refuse("'%s' is not a dotted key" % dotted)
for seg in segs:
    props = node.get("properties") if isinstance(node, dict) else None
    if not isinstance(props, dict) or seg not in props:
        refuse("key '%s' is not declared in the schema" % dotted)
    node = props[seg]
leaf = node

types = leaf.get("type", [])
if isinstance(types, str):
    types = [types]
scalar = [t for t in types if t in ("string", "boolean", "integer", "number")]
if not scalar:
    refuse("key '%s' is not a scalar leaf" % dotted)

value = None
done = False
if "boolean" in scalar and raw in ("true", "false"):
    value, done = (raw == "true"), True
if not done and ("integer" in scalar or "number" in scalar) and re.fullmatch(r"-?[0-9]+", raw):
    value, done = int(raw), True
if not done and "number" in scalar and re.fullmatch(r"-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?", raw):
    value, done = float(raw), True
if not done and "string" in scalar:
    value, done = raw, True
if not done:
    refuse("value '%s' is not a valid %s for key '%s'" % (raw, "/".join(scalar), dotted))

enum = leaf.get("enum")
if isinstance(enum, list):
    members = [m for m in enum if m is not None]
    if value not in members:
        refuse("value '%s' is not one of: %s (key '%s')" % (raw, ", ".join(str(m) for m in members), dotted))

try:
    import jsonschema
except ImportError:
    jsonschema = None
if jsonschema is not None:
    try:
        jsonschema.validate(instance=value, schema=leaf)
    except Exception as exc:
        first = (str(exc).splitlines() or [type(exc).__name__])[0]
        refuse("value '%s' fails the schema for key '%s' (%s)" % (raw, dotted, first))

sys.stdout.write(json.dumps(segs) + "\n" + json.dumps(value) + "\n")
PY

# profile_user_manifest set <dotted.key> <value> [--manifest PATH]
profile_user_manifest() {
  local sub="${1:-}" key="" val="" have_key=0 have_val=0 manifest="" schema out prc path_json val_json
  [ "$sub" = "set" ] || fs_refuse "user-manifest takes 'set' (usage: field-set.sh user-manifest set <dotted.key> <value> [--manifest PATH])"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest)
        [ $# -ge 2 ] && [ -n "$2" ] || fs_refuse "--manifest needs a path"
        manifest="$2"; shift 2 ;;
      --manifest=*)
        manifest="${1#--manifest=}"
        [ -n "$manifest" ] || fs_refuse "--manifest needs a path"
        shift ;;
      --)
        shift ;;
      --*)
        fs_refuse "unknown flag '$1'" ;;
      *)
        if [ "$have_key" -eq 0 ]; then key="$1"; have_key=1
        elif [ "$have_val" -eq 0 ]; then val="$1"; have_val=1
        else fs_refuse "unexpected argument '$1'"
        fi
        shift ;;
    esac
  done
  [ "$have_key" -eq 1 ] && [ "$have_val" -eq 1 ] || fs_refuse "usage: field-set.sh user-manifest set <dotted.key> <value> [--manifest PATH]"

  fs_need_tools
  [ -n "$manifest" ] || manifest="${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
  [ -f "$manifest" ] || fs_refuse "no user manifest at $manifest (the setter never creates it)"
  jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || fs_refuse "$manifest is not a parseable JSON object"
  schema="${CLAUDE_HOME:-$HOME/.claude}/schemas/user-manifest-schema.json"
  [ -f "$schema" ] || fs_refuse "no schema at $schema"

  out="$(python3 -c "$FS_PY_LEAF" "$schema" "$key" "$val")"
  prc=$?
  if [ "$prc" -eq 2 ]; then exit 2; fi
  [ "$prc" -eq 0 ] || fs_refuse "validation failed unexpectedly (python3 exit $prc)"
  path_json="$(printf '%s\n' "$out" | sed -n 1p)"
  val_json="$(printf '%s\n' "$out" | sed -n 2p)"

  fs_jq_write "$manifest" --argjson p "$path_json" --argjson v "$val_json" 'setpath($p; $v)'
  printf 'field-set: user-manifest %s set\n' "$key"
}

# The settings profile's jq programs. FS_JQ_HOOK_DEFS is prepended to the first two. An entry
# matches a basename when its command is the basename or ends in /<basename>; a group is the
# object under an event that carries a `hooks` array of entries.
IFS= read -r -d '' FS_JQ_HOOK_DEFS <<'JQ'
def ismatch($b):
  type == "object"
  and ((.command // null) | type) == "string"
  and (.command == $b or (.command | endswith("/" + $b)));
def gh:
  if type == "object" and ((.hooks // null) | type) == "array" then .hooks else null end;
def gdies($b):
  gh as $h
  | $h != null and ($h | length) > 0
    and (($h | map(select(ismatch($b))) | length) == ($h | length));
JQ

# Records of what `off` removes: one per matching entry, in event, group and entry order, with
# the group object (its hooks emptied) on the first record of a group the removal empties and the
# event key's position among the `.hooks` keys on the first record of an event it empties.
IFS= read -r -d '' FS_JQ_HOOK_RECORDS <<'JQ'
(.hooks // {}) as $H
| if ($H | type) != "object" then []
  else
    [ ($H | keys_unsorted | to_entries[]) as $ek
      | $ek.value as $ev
      | ($H[$ev] | if type == "array" then . else [] end) as $groups
      | (($groups | length) > 0 and ($groups | all(gdies($b)))) as $edies
      | ($groups | to_entries[]) as $g
      | select(($g.value | gh) != null)
      | ($g.value | gh) as $gl
      | [ $gl | to_entries[] | select(.value | ismatch($b)) ] as $ms
      | select(($ms | length) > 0)
      | ($g.value | gdies($b)) as $gdie
      | $ms | to_entries[]
      | . as $m
      | { event: $ev, group_index: $g.key, entry_index: $m.value.key, entry: $m.value.value }
        + (if $gdie and $m.key == 0 then { group: ($g.value | .hooks = []) } else {} end)
        + (if $edies and $g.key == 0 and $m.key == 0 then { event_key_position: $ek.key } else {} end)
    ]
  end
JQ

# The `off` edit: drop every matching entry, a group it empties, and an event key it leaves with
# no group. An event or group that was already empty before the call is left alone.
IFS= read -r -d '' FS_JQ_HOOK_OFF <<'JQ'
.hooks |= (
  . as $H
  | with_entries(
      .value |= (
        if type == "array" then
          map(
            if gdies($b) then empty
            elif gh != null then .hooks |= map(select(ismatch($b) | not))
            else . end
          )
        else . end
      )
    )
  | with_entries(select((.value | type) != "array" or (.value | length) > 0 or (($H[.key] | length) == 0)))
)
JQ

# The `on` edit: replay the records in order. An absent event key is recreated at its recorded
# position (at the end when none was recorded); a recorded group goes in at its recorded index
# clamped to the list length; an entry goes in at its recorded index clamped to the group length.
IFS= read -r -d '' FS_JQ_HOOK_ON <<'JQ'
reduce $r[] as $rec (
  (if (.hooks | type) == "object" then . else .hooks = {} end);
  (if (.hooks | has($rec.event)) then .
   else .hooks |= (
     to_entries as $es
     | (if $rec.event_key_position != null then ([$rec.event_key_position, ($es | length)] | min) else ($es | length) end) as $p
     | ($es[0:$p] + [{key: $rec.event, value: []}] + $es[$p:])
     | from_entries
   ) end)
  | (if $rec.group != null then
       .hooks[$rec.event] |= (
         . as $gs
         | ([$rec.group_index, ($gs | length)] | min) as $p
         | $gs[0:$p] + [$rec.group] + $gs[$p:]
       )
     else . end)
  | (.hooks[$rec.event] | length) as $n
  | if $n == 0 then error("no hook group under '" + $rec.event + "' to restore into")
    else
      ([$rec.group_index, $n - 1] | min) as $gi
      | .hooks[$rec.event][$gi].hooks |= (
          . as $es
          | ([$rec.entry_index, ($es | length)] | min) as $p
          | $es[0:$p] + [$rec.entry] + $es[$p:]
        )
    end
)
JQ

# The `on` pre-filter: marks a recorded entry `dup` when the settings already carry an entry with
# the same command under that event (an upgrade re-landed it), judged on the document before the replay.
IFS= read -r -d '' FS_JQ_HOOK_MARK <<'JQ'
. as $d | $r | map(. as $rec | . + {dup: ([($d.hooks | if type == "object" then .[$rec.event] else null end) | if type == "array" then .[] else empty end | (.hooks // [])[]? | .command?] | any(. == $rec.entry.command))})
JQ

# fs_settings_path: the settings file the settings profile edits (--settings PATH, else the default).
fs_settings_path() {
  printf '%s\n' "${FS_SETTINGS:-${CLAUDE_HOME:-$HOME/.claude}/settings.json}"
}

# fs_settings_check <path>: the file exists and is a JSON object.
fs_settings_check() {
  [ -f "$1" ] || fs_refuse "no settings file at $1"
  jq -e 'type == "object"' "$1" >/dev/null 2>&1 || fs_refuse "$1 is not a parseable JSON object"
}

# fs_hook_basename_check <basename>: a plain file name, so it is safe as a record file name.
fs_hook_basename_check() {
  [[ "$1" =~ ^[A-Za-z0-9._+-]+$ ]] || fs_refuse "'$1' is not a hook basename (letters, digits and . _ + -)"
}

# settings hook off <hook-basename>
fs_settings_hook_off() {
  local b="${1:-}" settings sidecar_dir sidecar records count new req log
  [ $# -eq 1 ] && [ -n "$b" ] || fs_refuse "usage: field-set.sh settings hook off <hook-basename> [--settings PATH]"
  fs_hook_basename_check "$b"
  fs_need_tools
  settings="$(fs_settings_path)"
  fs_settings_check "$settings"
  [ -n "${HOOKS_STATE:-}" ] || fs_refuse "HOOKS_STATE is unresolved (paths.sh is missing beside this script)"
  sidecar_dir="$HOOKS_STATE/field-set-hook-off"
  sidecar="$sidecar_dir/$b.json"
  records="$(jq -c --arg b "$b" "$FS_JQ_HOOK_DEFS $FS_JQ_HOOK_RECORDS" "$settings")" || fs_refuse "jq could not read the hook entries of $settings"
  count="$(printf '%s\n' "$records" | jq 'length')" || fs_refuse "jq could not count the hook entries of $settings"
  if [ "$count" = "0" ]; then
    if [ -f "$sidecar" ]; then
      printf 'field-set: %s already off\n' "$b"
      return 0
    fi
    fs_refuse "no hook entry matches '$b'"
  fi
  new="$(jq --arg b "$b" "$FS_JQ_HOOK_DEFS $FS_JQ_HOOK_OFF" "$settings")" || fs_refuse "jq could not compute the edit of $settings"
  if ! printf '%s\n' "$new" | grep -qE 'memory-consolidation-check\.sh|claude-mem'; then
    if [ "${CLAUDE_MEM_DISABLE_OK:-0}" != "1" ]; then
      printf "field-set: refused: turning off '%s' would leave no memory-consolidation-check.sh or claude-mem entry in %s (R-24); set CLAUDE_MEM_DISABLE_OK=1 to override, which is logged\n" "$b" "$settings" >&2
      exit 3
    fi
    [ -n "${CLAUDE_STATE_ROOT:-}" ] || fs_refuse "CLAUDE_STATE_ROOT is unresolved, so the CLAUDE_MEM_DISABLE_OK override cannot be logged"
    log="$CLAUDE_STATE_ROOT/audit/hook-audit.log"
    mkdir -p "$CLAUDE_STATE_ROOT/audit" || fs_refuse "cannot create the audit directory beside $log"
    printf '%s | field-set | CLAUDE_MEM_DISABLE_OK override | %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$settings" >> "$log" || fs_refuse "cannot append to the audit log $log"
  fi
  mkdir -p "$sidecar_dir" || fs_refuse "cannot create the record directory $sidecar_dir"
  FS_TMP2="$(mktemp "$sidecar_dir/.field-set.XXXXXX")" || fs_refuse "cannot create a temp file in $sidecar_dir"
  printf '%s\n' "$records" | jq . > "$FS_TMP2" || fs_refuse "cannot write the off-state record for '$b'"
  mv -f "$FS_TMP2" "$sidecar" || fs_refuse "cannot place the off-state record $sidecar"
  FS_TMP2=""
  FS_SIDECAR_NEW="$sidecar"
  fs_jq_write "$settings" --arg b "$b" "$FS_JQ_HOOK_DEFS $FS_JQ_HOOK_OFF"
  FS_SIDECAR_NEW=""
  printf 'field-set: %s off\n' "$b"
  req="${CLAUDE_HOME:-$HOME/.claude}/templates/settings-required-hooks.json"
  if [ -f "$req" ] && jq -e --arg b "$b" '[.required_hooks[]? | .command // empty | select(. == $b or endswith("/" + $b))] | length > 0' "$req" >/dev/null 2>&1; then
    printf 'NOTE: %s is a foundation-required hook; the installer re-lands it on the next upgrade, so this opt-out does not survive an upgrade\n' "$b" >&2
  fi
}

# settings hook on <hook-basename>
fs_settings_hook_on() {
  local b="${1:-}" settings sidecar records
  [ $# -eq 1 ] && [ -n "$b" ] || fs_refuse "usage: field-set.sh settings hook on <hook-basename> [--settings PATH]"
  fs_hook_basename_check "$b"
  fs_need_tools
  settings="$(fs_settings_path)"
  [ -n "${HOOKS_STATE:-}" ] || fs_refuse "HOOKS_STATE is unresolved (paths.sh is missing beside this script)"
  sidecar="$HOOKS_STATE/field-set-hook-off/$b.json"
  [ -f "$sidecar" ] || fs_refuse "no recorded off-state for '$b'"
  jq -e 'type == "array"' "$sidecar" >/dev/null 2>&1 || fs_refuse "the off-state record $sidecar is not a JSON array"
  fs_settings_check "$settings"
  records="$(jq -c . "$sidecar")" || fs_refuse "cannot read the off-state record $sidecar"
  records="$(jq -c --argjson r "$records" "$FS_JQ_HOOK_MARK" "$settings")" || fs_refuse "jq could not check $settings against the off-state record"
  printf '%s\n' "$records" | jq -r --arg b "$b" '.[] | select(.dup) | "NOTE: \($b) already present under \(.event); not restored twice"' >&2
  records="$(printf '%s\n' "$records" | jq -c 'map(select(.dup | not) | del(.dup))')" || fs_refuse "jq could not filter the off-state record"
  if [ "$records" != "[]" ]; then fs_jq_write "$settings" --argjson r "$records" "$FS_JQ_HOOK_ON"; fi
  if ! rm -f "$sidecar"; then
    printf 'field-set: NOTE: %s is back on, but the off-state record %s could not be removed\n' "$b" "$sidecar" >&2
  fi
  printf 'field-set: %s on\n' "$b"
}

# settings env set <KEY> <value>
fs_settings_env_set() {
  local k="${1:-}" v="${2:-}" settings
  [ $# -eq 2 ] && [ -n "$k" ] || fs_refuse "usage: field-set.sh settings env set <KEY> <value> [--settings PATH]"
  [[ "$k" =~ ^[A-Z][0-9A-Z_]*$ ]] || fs_refuse "'$k' is not an environment variable name (upper-case letters, digits and underscores, starting with a letter)"
  fs_need_tools
  settings="$(fs_settings_path)"
  fs_settings_check "$settings"
  fs_jq_write "$settings" --arg k "$k" --arg v "$v" 'setpath(["env", $k]; $v)'
  printf 'field-set: settings env %s set\n' "$k"
}

# profile_settings hook off|on <hook-basename> | env set <KEY> <value>, each with [--settings PATH]
profile_settings() {
  local area="${1:-}" verb="${2:-}" n=$# a
  while [ "$n" -gt 0 ]; do
    a="$1"; shift; n=$((n - 1))
    case "$a" in
      --settings) [ "$n" -gt 0 ] && [ -n "$1" ] || fs_refuse "--settings needs a path"; FS_SETTINGS="$1"; shift; n=$((n - 1)) ;;
      --settings=*) FS_SETTINGS="${a#--settings=}"; [ -n "$FS_SETTINGS" ] || fs_refuse "--settings needs a path" ;;
      --*) fs_refuse "unknown flag '$a'" ;;
      *) set -- "$@" "$a" ;;
    esac
  done
  case "$area $verb" in
    "hook off") shift 2; fs_settings_hook_off "$@" ;;
    "hook on") shift 2; fs_settings_hook_on "$@" ;;
    "env set") shift 2; fs_settings_env_set "$@" ;;
    *) fs_refuse "settings takes 'hook off|on <hook-basename>' or 'env set <KEY> <value>'" ;;
  esac
}

# The plan profile's close rules, a twin of the ordering gate in
# skills/librarian/capabilities/session-close.sh: no terminal status over an open task ledger.
# TERMINAL_STATUS and NON_ADVANCED are the same literals as that gate's; a parity fixture
# compares them. Prints a `field-set: refused:` line and exits 3 when the gate refuses.
IFS= read -r -d '' FS_PY_GATE <<'PY'
import json
import os
import sys

path, target = sys.argv[1], sys.argv[2]

TERMINAL_STATUS = ("completed", "superseded")

NON_ADVANCED = frozenset((
    "", "null", "none",
    "not-started", "planned", "pending", "in-progress", "proposed",
    "blocked", "needs-revision",
))


def task_state(t):
    v = t.get("status")
    if v is None:
        return ""
    if not isinstance(v, str):
        v = str(v)
    return v.split("(")[0].strip().lower().replace("_", "-")


try:
    with open(path, encoding="utf-8") as fh:
        m = json.load(fh)
except Exception as exc:
    sys.stderr.write("field-set: refused: cannot read %s (%s)\n" % (path, exc))
    sys.exit(2)

if target in TERMINAL_STATUS:
    rows = []
    tasks = m.get("tasks") if isinstance(m, dict) else None
    for t in (tasks if isinstance(tasks, list) else []):
        if isinstance(t, dict) and task_state(t) in NON_ADVANCED:
            rows.append((str(t.get("id") or "?"), task_state(t) or "null"))
    if rows:
        shown = ", ".join("%s:%s" % (i, s) for i, s in rows[:5])
        if len(rows) > 5:
            shown += ", +%d more" % (len(rows) - 5)
        sys.stderr.write(
            "field-set: refused: %s - status=%s over %d non-advanced task row(s) [%s]; "
            "REFUSING the status, completed_at and research_closed write (advance or cut the rows, then retry)\n"
            % (os.path.basename(os.path.dirname(os.path.abspath(path))), target, len(rows), shown)
        )
        sys.exit(3)
PY

# fs_plan_rules: print the plans rules document (an object carrying `.lifecycle`) from the
# backlog-index.sh chain: PLANS_RULES_PATH, then $CLAUDE_HOME/governance/plans-rules.json, then
# foundation-overlay-load.sh --query '.plans' --force-override. Returns 1 when none resolves.
fs_plan_rules() {
  local ch="${CLAUDE_HOME:-$HOME/.claude}" cand loader out
  for cand in "${PLANS_RULES_PATH:-}" "$ch/governance/plans-rules.json"; do
    if [ -n "$cand" ] && [ -f "$cand" ]; then cat "$cand"; return 0; fi
  done
  for loader in "$ch/hooks/lib/foundation-overlay-load.sh" "$SCRIPT_DIR/foundation-overlay-load.sh"; do
    [ -x "$loader" ] || continue
    out="$(bash "$loader" --query '.plans' --force-override 2>/dev/null)" || continue
    if [ -n "$out" ] && [ "$out" != "null" ]; then printf '%s\n' "$out"; return 0; fi
  done
  return 1
}

# The LAG filter: reads the findings file of plan-terminal-lag-check.sh and prints one
# `LAG: plan_slug=<s> plan_status=<s> parent_plan=<p> parent_status=<s>` line per finding whose
# parent_plan resolves, by the capability's own resolve_parent_dir (the exact directory under the
# plans root, else the first sorted *-<parent_plan> directory), to the written plan's directory.
IFS= read -r -d '' FS_PY_LAG <<'PY'
import glob
import json
import os
import sys

findings, root, written = sys.argv[1], sys.argv[2], os.path.realpath(sys.argv[3])


def resolve_parent_dir(parent_slug):
    exact = os.path.join(root, parent_slug)
    if os.path.isdir(exact):
        return exact
    matches = sorted(g for g in glob.glob(os.path.join(root, "*-" + parent_slug)) if os.path.isdir(g))
    return matches[0] if matches else None


try:
    with open(findings, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
except OSError:
    lines = []
for line in lines:
    try:
        f = json.loads(line)
    except ValueError:
        continue
    if not isinstance(f, dict) or f.get("finding") != "plan-terminal-lag":
        continue
    parent = str(f.get("parent_plan", "")).strip()
    pd = resolve_parent_dir(parent) if parent else None
    if pd is None or os.path.realpath(pd) != written:
        continue
    print("LAG: plan_slug=%s plan_status=%s parent_plan=%s parent_status=%s"
          % (f.get("plan_slug", ""), f.get("plan_status", ""), parent, f.get("parent_status", "")))
PY

# fs_plan_derive <manifest> <resulting status>: after a plan write, the derivations a tool-event
# write of the manifest would have fired, each failing open with a NOTE when its hook is
# missing: the binder and tasks.md re-render (post-manifest-binder-refresh.sh), the manifest verify
# and library-promotion queue (post-tool-use-manifest.sh, fed a PostToolUse payload), and, after a
# terminal write only, the lag check, whose findings that belong to the written plan are printed as
# `LAG:` lines. Nothing is written downward: a sub-plan that lags is surfaced, never edited.
fs_plan_derive() {
  local manifest="$1" status="$2" ch="${CLAUDE_HOME:-$HOME/.claude}" abs hook cap root
  case "$manifest" in /*) abs="$manifest" ;; *) abs="$(pwd)/$manifest" ;; esac
  hook="$ch/hooks/post-manifest-binder-refresh.sh"
  if [ -f "$hook" ]; then bash "$hook" "$abs" </dev/null >/dev/null 2>&1
  else printf 'NOTE: binder refresh skipped (%s is missing)\n' "$hook" >&2; fi
  hook="$ch/hooks/post-tool-use-manifest.sh"
  if [ -f "$hook" ]; then jq -n --arg p "$abs" '{tool_name: "Write", tool_input: {file_path: $p}}' | bash "$hook" >/dev/null 2>&1
  else printf 'NOTE: manifest-verify skipped (%s is missing)\n' "$hook" >&2; fi
  case "$status" in completed|superseded) ;; *) return 0 ;; esac
  cap="$ch/skills/librarian/capabilities/plan-terminal-lag-check.sh"
  if [ ! -f "$cap" ]; then printf 'NOTE: lag check skipped (%s is missing)\n' "$cap" >&2; return 0; fi
  root="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
  FS_LAGOUT="$(mktemp "${TMPDIR:-/tmp}/field-set-lag.XXXXXX")" || return 0
  PLANS_ROOT="$root" FINDINGS_OUTPUT="$FS_LAGOUT" bash "$cap" >/dev/null 2>&1
  python3 -c "$FS_PY_LAG" "$FS_LAGOUT" "$root" "$(dirname "$abs")"
  rm -f "$FS_LAGOUT"
  FS_LAGOUT=""
}

# fs_plan_enum <property>: the members of plan-manifest-schema.json :: properties.<property>.enum, one
# per line. Run in a command substitution, so a refusal is the caller's `|| exit 2`.
fs_plan_enum() {
  local schema="${CLAUDE_HOME:-$HOME/.claude}/schemas/plan-manifest-schema.json"
  [ -f "$schema" ] || fs_refuse "no schema at $schema"
  jq -r --arg p "$1" '.properties[$p].enum[]' "$schema" || fs_refuse "no $1 enum in $schema"
}

# profile_plan set <manifest.json> <field>=<value> [<field>=<value> ...]
# The settable fields are status, paused_reason and disposition.
profile_plan() {
  local sub="${1:-}" manifest fields="" arg k v to="" reason="" have_reason=0 disp="" have_disp=0 cur rules edges
  local members project slug today prog drc cap prc
  [ "$sub" = "set" ] || fs_refuse "plan takes 'set' (usage: field-set.sh plan set <manifest.json> <field>=<value> [<field>=<value> ...])"
  shift
  manifest="${1:-}"
  [ -n "$manifest" ] && [ $# -ge 2 ] || fs_refuse "usage: field-set.sh plan set <manifest.json> <field>=<value> [<field>=<value> ...]"
  shift
  for arg in "$@"; do
    [[ "$arg" == *=* ]] || fs_refuse "'$arg' is not <field>=<value>"
    k="${arg%%=*}"; v="${arg#*=}"
    case " $fields " in *" $k "*) fs_refuse "field '$k' is given twice" ;; esac
    case "$k" in
      status) [ -n "$v" ] || fs_refuse "status needs a value"; to="$v" ;;
      paused_reason) reason="$v"; have_reason=1 ;;
      disposition) disp="$v"; have_disp=1 ;;
      *) fs_refuse "field '$k' is not settable by plan set" ;;
    esac
    fields="$fields $k"
  done
  fs_need_tools
  [ -f "$manifest" ] || fs_refuse "no manifest at $manifest"
  jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || fs_refuse "$manifest is not a parseable JSON object"
  jq -e 'has("status") or has("tasks")' "$manifest" >/dev/null 2>&1 || fs_refuse "not a plan manifest"
  cur="$(jq -r '.status // ""' "$manifest")"
  if [ -n "$to" ]; then
    rules="$(fs_plan_rules)" || fs_refuse "no plans rules source resolved"
    printf '%s\n' "$rules" | jq -e --arg s "$to" '.lifecycle.status_enum | index($s) != null' >/dev/null 2>&1 || fs_refuse "status '$to' is not in lifecycle.status_enum"
    edges="$(printf '%s\n' "$rules" | jq -r '.lifecycle.transitions | keys[] | if contains("<->") then (split("<->") | (.[0] + "->" + .[1]), (.[1] + "->" + .[0])) else . end')" || fs_refuse "the plans rules carry no lifecycle.transitions"
    printf '%s\n' "$edges" | grep -qxF "$cur->$to" || fs_refuse "no transition $cur->$to in lifecycle.transitions"
  fi
  if [ "$have_reason" -eq 1 ]; then
    members="$(fs_plan_enum paused_reason)" || exit 2
    printf '%s\n' "$members" | grep -qxF -- "$reason" || fs_refuse "paused_reason '$reason' is not one of: $(printf '%s' "$members" | tr '\n' ' ')"
  fi
  if [ "$have_disp" -eq 1 ]; then
    members="$(fs_plan_enum disposition)" || exit 2
    printf '%s\n' "$members" | grep -qxF -- "$disp" || fs_refuse "disposition '$disp' is not one of: $(printf '%s' "$members" | tr '\n' ' ')"
  fi
  if [ "$have_reason" -eq 1 ] && [ "${to:-$cur}" != "paused" ]; then
    fs_refuse "paused_reason is only valid with status=paused"
  fi
  if [ "$to" = "paused" ] && [ "$have_reason" -eq 0 ]; then
    fs_refuse "paused requires paused_reason"
  fi
  today="${SESSION_CLOSE_TODAY:-$(date '+%Y-%m-%d')}"
  prog='.updated = $u'
  [ -z "$to" ] || prog="$prog | .status = \$s"
  [ "$cur->$to" != "paused->in-progress" ] || prog="$prog | del(.paused_reason)"
  [ "$have_reason" -eq 0 ] || prog="$prog | .paused_reason = \$r"
  [ "$have_disp" -eq 0 ] || prog="$prog | .disposition = \$d"
  if [ "$to" = "completed" ]; then
    python3 -c "$FS_PY_GATE" "$manifest" "$to"
    prc=$?
    [ "$prc" -eq 0 ] || exit "$prc"
    project="$(jq -r '.project // ""' "$manifest")"
    [ -n "$project" ] || fs_refuse "$manifest has no project, so plan-research-declare cannot name its spoke; status not written"
    cap="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/plan-research-declare.sh"
    drc=127
    if [ -f "$cap" ]; then bash "$cap" --spoke "$project" >/dev/null; drc=$?; fi
    [ "$drc" -eq 0 ] || fs_refuse "plan-research-declare unavailable or failed (rc $drc); status not written"
    prog="$prog | (if (.completed_at // \"\") == \"\" then .completed_at = \$u else . end) | .research_closed = true"
  fi
  fs_jq_write "$manifest" --arg s "$to" --arg u "$today" --arg r "$reason" --arg d "$disp" "$prog"
  slug="$(basename "$(dirname "$manifest")")"
  printf 'field-set: plan %s set:%s\n' "$slug" "$(printf ' %s' "$@")"
  fs_plan_derive "$manifest" "${to:-$cur}"
}

# profile_capture_freeze open|lift <spoke> [--plans-root DIR]
# The record path comes from inbox.capture_freeze_record in the plans rules (the reader's own source).
profile_capture_freeze() {
  local verb="${1:-}" spoke="" root="" rules pattern rec recdir sha top real_top real_root
  case "$verb" in
    open|lift) ;;
    *) fs_refuse "capture-freeze takes 'open <spoke>' or 'lift <spoke>' (usage: field-set.sh capture-freeze open|lift <spoke> [--plans-root DIR])" ;;
  esac
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --plans-root)
        [ $# -ge 2 ] && [ -n "$2" ] || fs_refuse "--plans-root needs a directory"
        root="$2"; shift 2 ;;
      --plans-root=*)
        root="${1#--plans-root=}"
        [ -n "$root" ] || fs_refuse "--plans-root needs a directory"
        shift ;;
      --*)
        fs_refuse "unknown flag '$1'" ;;
      *)
        [ -z "$spoke" ] || fs_refuse "unexpected argument '$1'"
        spoke="$1"; shift ;;
    esac
  done
  [ -n "$spoke" ] || fs_refuse "usage: field-set.sh capture-freeze open|lift <spoke> [--plans-root DIR]"
  [ -n "$root" ] || root="${PLANS_ROOT:-${PLANS_DIR:-}}"
  [ -n "$root" ] || fs_refuse "no plans root (pass --plans-root DIR or set PLANS_ROOT)"
  fs_need_tools
  if [ "$verb" = "open" ]; then
    top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || top=""
    real_top=""
    if [ -n "$top" ]; then real_top="$(cd "$top" 2>/dev/null && pwd -P)"; fi
    real_root="$(cd "$root" 2>/dev/null && pwd -P)"
    if [ -z "$real_top" ] || [ "$real_top" != "$real_root" ]; then fs_refuse "plans root is not a git repository"; fi
  fi
  [[ "$spoke" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || fs_refuse "spoke '$spoke' is not a plain key"
  rules="$(fs_plan_rules)" || fs_refuse "no plans rules source resolved"
  pattern="$(printf '%s\n' "$rules" | jq -r '.inbox.capture_freeze_record // ""')"
  case "$pattern" in *"<spoke>"*) ;; *) fs_refuse "the plans rules carry no inbox.capture_freeze_record with a <spoke> placeholder" ;; esac
  rec="${root%/}/${pattern//\<spoke\>/$spoke}"
  recdir="$(dirname "$rec")"
  if [ "$verb" = "lift" ]; then
    if [ -e "$rec" ]; then
      rm -f "$rec" || fs_refuse "cannot remove $rec"
      printf 'field-set: capture-freeze lift %s removed\n' "$spoke"
    else
      printf 'field-set: capture-freeze lift %s: no freeze in force\n' "$spoke"
    fi
    return 0
  fi
  [ -d "$recdir" ] || fs_refuse "no ${recdir#"${root%/}/"} directory"
  if [ -e "$rec" ]; then
    printf 'field-set: refused: a freeze is already open for %s\n' "$spoke" >&2
    exit 3
  fi
  sha="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$root" rev-parse HEAD 2>/dev/null)" || sha=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fs_refuse "the plans repository has no commit to record"
  FS_TMP="$(mktemp "$recdir/.field-set.XXXXXX")" || fs_refuse "cannot create a temp file in $recdir"
  printf 'start_sha=%s\n' "$sha" > "$FS_TMP" || fs_refuse "cannot write the freeze record"
  mv -f "$FS_TMP" "$rec" || fs_refuse "cannot place the freeze record $rec"
  FS_TMP=""
  printf 'field-set: capture-freeze open %s start_sha=%s\n' "$spoke" "$sha"
}

# fs_run_write <profile function> <args...>: the one door every profile's write path goes through.
# Unless this already is the locked child, re-exec the script (profile name and arguments
# unchanged) as one /usr/bin/lockf -k -t 2 child on $HOOKS_STATE/field-set.lock and pass its rc
# through; the locked child sets FIELD_SET_LOCKED and runs the profile inline.
fs_run_write() {
  local fn="$1" lock rc=0
  shift
  if [ -z "${FIELD_SET_LOCKED:-}" ] && [ -x /usr/bin/lockf ]; then
    [ -n "${HOOKS_STATE:-}" ] || fs_refuse "HOOKS_STATE is unresolved (paths.sh is missing beside this script)"
    lock="$HOOKS_STATE/field-set.lock"
    mkdir -p "$HOOKS_STATE" || fs_refuse "cannot create the state directory $HOOKS_STATE"
    FIELD_SET_LOCKED=1 /usr/bin/lockf -k -t 2 "$lock" "${BASH:-bash}" "$FS_SELF" "$FS_PROFILE" "$@" || rc=$?
    if [ "$rc" -eq 75 ]; then
      printf 'field-set: lock contention on %s (rc 75); nothing was written\n' "$lock" >&2
    fi
    exit "$rc"
  fi
  fs_install_traps
  "$fn" "$@"
}

main() {
  local profile="${1:-}"
  case "$profile" in
    -h|--help|help) fs_usage; exit 0 ;;
    "") fs_usage >&2; exit 2 ;;
  esac
  shift
  FS_PROFILE="$profile"
  case "$profile" in
    user-manifest) fs_run_write profile_user_manifest "$@" ;;
    settings) fs_run_write profile_settings "$@" ;;
    plan) fs_run_write profile_plan "$@" ;;
    capture-freeze) fs_run_write profile_capture_freeze "$@" ;;
    *) printf "field-set: unknown profile '%s'\n" "$profile" >&2; exit 2 ;;
  esac
}

main "$@"
