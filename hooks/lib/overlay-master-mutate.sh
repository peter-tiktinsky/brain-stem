#!/usr/bin/env bash
# hooks/lib/overlay-master-mutate.sh — atomic-write library for mutating
# $CLAUDE_HOME/governance/overlay-master.json under R-37 multi-pillar lockstep.
#
# Per alignment (atomic-write contract) +
# (system.timezone slot). Authored under Batch B T-8.
#
# amendment: top-level lib/ does NOT exist in brain-stem — this
# body lives at hooks/lib/overlay-master-mutate.sh, co-located with its
# consumer skills/govern/process.sh + the 4 modes. The merge-strategy-registry
# is a sibling under hooks/lib/. Hook-portability: NO $HOME/.claude
# literal — resolve via $CLAUDE_HOME (install-convention base).
#
# Invoked by:
#   - /govern register skill (skills/govern/process.sh) — semantic-extension flow
#   - Future overlay-mutating capabilities (Class A/B/C/D hook nudges)
#
# R-52 collision tiebreaker: when same key exists in foundation-master AND
# overlay-master, overlay wins (adopter override semantics). The mutation
# library does NOT enforce override-reason capture itself — that is the
# /govern register skill body's responsibility (write-time UX). This library
# trusts caller-supplied payloads conforming to the schema.
#
# R-37 multi-pillar bundling: N>1 pillar mutations in a single invocation
# all apply atomically or NONE apply. Single tempfile; single atomic rename.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`, no `${var,,}`).
# Canonical lock pattern: /usr/bin/lockf -k -t 0 (kernel-backed; not flock).

set -u

# ---- original argv capture (bash-3.2 empty-safe re-exec forwarding) ---
# Capture the ORIGINAL argv into an indexed array immediately after set -u,
# BEFORE the parse loop below consumes $@ via shift, so the lockf re-exec can
# forward it verbatim + empty-safe. This replaces the hand-rolled unquoted
# REEXEC_ARGS string rebuild that let a --target 'Work/<spoke>/**' word-split /
# glob-expand against cwd at the re-exec. Indexed array = bash-3.2-safe.
_BS_ORIG_ARGV=("$@")

# ---- path base (Hook-portability: $CLAUDE_HOME, no $HOME/.claude literal) ----

_BS_CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# ---- defaults ---------------------------------------------------------------

if [ -z "${OVERLAY_MASTER:-}" ]; then
  OVERLAY_MASTER="$_BS_CLAUDE_HOME/governance/overlay-master.json"
fi

# SCHEMA default. Install-layout: $CLAUDE_HOME/schemas/. Foundation-repo layout:
# hooks/lib/ -> ../../schemas/ (repo-root sibling). Env $SCHEMA overrides.
if [ -z "${SCHEMA:-}" ]; then
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  if [ -r "$_BS_CLAUDE_HOME/schemas/overlay-master-schema.json" ]; then
    SCHEMA="$_BS_CLAUDE_HOME/schemas/overlay-master-schema.json"
  else
    SCHEMA="$SCRIPT_DIR/../../schemas/overlay-master-schema.json"
  fi
fi

if [ -z "${ACTION_LOG:-}" ]; then
  ACTION_LOG="${CLAUDE_HOME:-$HOME/.claude}/governance/governance-action-log.jsonl"
fi

# Per-leaf merge-strategy registry. Declared UNION leaves get array
# concat+dedup at write-time; everything else uses default jq `*` deep-merge.
# Default path: the merge-strategy-registry.json sibling under hooks/lib/.
# Env override $MERGE_REGISTRY supported for fixture testing.
if [ -z "${MERGE_REGISTRY:-}" ]; then
  if [ -z "${SCRIPT_DIR:-}" ]; then
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  fi
  MERGE_REGISTRY="$SCRIPT_DIR/merge-strategy-registry.json"
fi

# Parallel arrays (bash 3.2 — no associative arrays).
# PILLARS[i] holds the pillar name; PAYLOAD_FILES[i] holds the matching path.
PILLARS=""
PAYLOAD_FILES=""
PILLAR_COUNT=0
DRY_RUN=0
PROPOSED_BY="user-direct"
KIND=""
TARGET=""
RETRACT=0
RETRACT_PATTERN=""

usage() {
  cat <<EOF
overlay-master-mutate.sh — atomic R-37 overlay-master mutation library.

Usage:
  overlay-master-mutate.sh \\
      --pillar <pillar-name> --payload-file <path-to-json-mutation> \\
      [--pillar <name2> --payload-file <path2> ...] \\
      [--kind <folder-registered|file-type-registered|...>] \\
      [--target <target-string>] \\
      [--proposed-by <enum-value>] \\
      [--dry-run]

Required:
  --pillar          Pillar slot name. One of:
                    frontmatter / tagging / naming / mandatory_files /
                    doc_dependencies / file_type_contracts / vault_writers /
                    plans / system.
  --payload-file    Path to JSON file containing the mutation payload for the
                    paired --pillar. Payload is deep-merged into the pillar
                    slot under R-52 (overlay wins on key collision).

Multi-pillar R-37 bundling:
  Repeat --pillar / --payload-file pairs in order. All mutations apply
  atomically or none do (single tempfile, single rename).

Retract a path_routing rule (instead of --pillar / --payload-file):
  overlay-master-mutate.sh --retract-rule <pattern> \\
      [--kind folder] [--target <target-string>] \\
      [--proposed-by <enum-value>] [--dry-run]
  --retract-rule    Remove every frontmatter.path_routing.rules element whose
                    pattern equals <pattern> exactly (string equality, no glob),
                    under the same lock, schema check and atomic rename, and
                    append one action-log row. Exclusive with --pillar and
                    --payload-file. Exit 0 with a "nothing retracted" line (no
                    write, no row) when no rule matches; exit 4 when
                    path_routing is a bare array (the legacy shape).

Optional:
  --kind            Mutation kind for action-log row. Enum per
                    schemas/governance-action-log-schema.json:
                    folder / file-type / tag-extension / writer.
                    Required if not --dry-run.
  --target          Target string for action-log (folder path, file-type
                    slug, tag dimension, writer name).
  --proposed-by     Entry-path enum per action-log schema. Default: user-direct.
  --dry-run         Run validation only; do NOT mv tempfile; do NOT append
                    to action-log. Foundation-repo CI mode.

Env:
  OVERLAY_MASTER    Default \$CLAUDE_HOME/governance/overlay-master.json.
  SCHEMA            Default \$CLAUDE_HOME/schemas/overlay-master-schema.json
                    (foundation-repo fallback: ../../schemas/).
  ACTION_LOG        Default \$CLAUDE_HOME/governance/governance-action-log.jsonl
                    (.1:38 — the action-log is homed under governance/).
  MERGE_REGISTRY    Default sibling hooks/lib/merge-strategy-registry.json.
  CLAUDE_SESSION_ID Read for action-log session_id field; falls back to
                    "unknown-session" if unset.

Exit codes:
  0   success (or dry-run validation passed)
  2   bad invocation / missing prereq
  3   pre-flight failure
  4   schema validation failure
  5   lock contention
  6   atomic rename or action-log append failure
EOF
}

# ---- failure-mode helper ----------------------------------------------------
#
# Called from pre-commit failure paths to ensure block-and-log discipline:
# tempfile already deleted by caller; this writes an action-log row with the
# failure reason so librarian governance-parity-audit surfaces the rejection.

_append_failed_action_log() {
  # $1 pillar(s) string, $2 payload-files string, $3 reason
  if [ -z "${KIND:-}" ]; then
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  local pillar_s="$1" reason="$3"
  local ts session_id
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  session_id="${CLAUDE_SESSION_ID:-unknown-session}"
  mkdir -p "$(dirname "$ACTION_LOG")" 2>/dev/null || true
  local row
  row=$(jq -nc \
    --arg timestamp "$ts" \
    --arg kind "$KIND" \
    --arg proposed_by "$PROPOSED_BY" \
    --arg session_id "$session_id" \
    --arg target "$TARGET" \
    --arg pillar "$pillar_s" \
    --arg reason "$reason" \
    '
      {
        timestamp: $timestamp,
        kind: $kind,
        proposed_by: $proposed_by,
        session_id: $session_id,
        target: ($target | if . == "" then null else . end),
        rejected_fields: { ($pillar): { reason: $reason } },
        unregistered: false
      }
      | with_entries(select(.value != null))
    ' 2>/dev/null)
  if [ -n "$row" ]; then
    printf '%s\n' "$row" >> "$ACTION_LOG" 2>/dev/null || true
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pillar)
      PILLARS="$PILLARS $2"
      shift 2
      ;;
    --payload-file)
      PAYLOAD_FILES="$PAYLOAD_FILES $2"
      PILLAR_COUNT=$((PILLAR_COUNT + 1))
      shift 2
      ;;
    --kind)            KIND="$2"; shift 2 ;;
    --target)          TARGET="$2"; shift 2 ;;
    --proposed-by)     PROPOSED_BY="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --retract-rule)
      # Value-taking flag under `set -u`: read the value with ${2-} and shift past
      # it only when one is present, so a trailing flag is refused, never looped on.
      RETRACT=1
      RETRACT_PATTERN="${2-}"
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    -h|--help)         usage; exit 0 ;;
    *) printf 'overlay-master-mutate.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- retract-rule argv validation --------------------------------------------

if [ "$RETRACT" = "1" ]; then
  if [ -z "$RETRACT_PATTERN" ]; then
    printf 'overlay-master-mutate.sh: --retract-rule requires a non-empty pattern\n' >&2
    exit 2
  fi
  if [ "$PILLAR_COUNT" != "0" ] || [ -n "$PILLARS" ]; then
    printf 'overlay-master-mutate.sh: --retract-rule cannot be combined with --pillar/--payload-file\n' >&2
    exit 2
  fi
fi

# ---- argv validation --------------------------------------------------------

if [ "$PILLAR_COUNT" = "0" ] && [ "$RETRACT" = "0" ]; then
  printf 'overlay-master-mutate.sh: at least one --pillar + --payload-file pair required\n' >&2
  exit 2
fi

# Validate parity: count of pillar args must match count of payload args.
PILLAR_ARG_COUNT=$(printf '%s\n' $PILLARS | wc -w | tr -d ' ')
if [ "$PILLAR_ARG_COUNT" != "$PILLAR_COUNT" ]; then
  printf 'overlay-master-mutate.sh: unmatched --pillar/--payload-file pairs (pillars=%s, payloads=%s)\n' \
    "$PILLAR_ARG_COUNT" "$PILLAR_COUNT" >&2
  exit 2
fi

# Validate pillar names against schema's known top-level slots.
VALID_PILLARS="frontmatter tagging naming mandatory_files doc_dependencies file_type_contracts vault_writers plans system"
for p in $PILLARS; do
  found=0
  for valid in $VALID_PILLARS; do
    if [ "$p" = "$valid" ]; then
      found=1
      break
    fi
  done
  if [ "$found" = "0" ]; then
    printf 'overlay-master-mutate.sh: unknown pillar: %s (valid: %s)\n' "$p" "$VALID_PILLARS" >&2
    exit 2
  fi
done

# Validate --kind required if not dry-run.
if [ "$DRY_RUN" = "0" ] && [ -z "$KIND" ]; then
  printf 'overlay-master-mutate.sh: --kind required (unless --dry-run)\n' >&2
  exit 2
fi

# ---- pre-flight -------------------------------------------------------------

for tool in jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'overlay-master-mutate.sh: missing prereq: %s\n' "$tool" >&2
    exit 3
  fi
done

# Validate jsonschema is available via python3.
if ! python3 -c 'import jsonschema' 2>/dev/null; then
  printf 'overlay-master-mutate.sh: python3 jsonschema module required\n' >&2
  exit 3
fi

if [ ! -r "$SCHEMA" ]; then
  printf 'overlay-master-mutate.sh: SCHEMA not readable: %s\n' "$SCHEMA" >&2
  exit 3
fi

# Validate schema itself can be loaded by Python.
if ! python3 -c "
import json, sys
with open('$SCHEMA') as f:
    schema = json.load(f)
" 2>/dev/null; then
  printf 'overlay-master-mutate.sh: SCHEMA is not parseable JSON: %s\n' "$SCHEMA" >&2
  exit 3
fi

# Validate every payload file is parseable JSON.
for pf in $PAYLOAD_FILES; do
  if [ ! -r "$pf" ]; then
    printf 'overlay-master-mutate.sh: payload-file not readable: %s\n' "$pf" >&2
    exit 3
  fi
  if ! jq empty "$pf" >/dev/null 2>&1; then
    printf 'overlay-master-mutate.sh: payload-file not valid JSON: %s\n' "$pf" >&2
    exit 3
  fi
done

# Ensure overlay-master parent dir exists.
OVERLAY_DIR=$(dirname "$OVERLAY_MASTER")
mkdir -p "$OVERLAY_DIR" 2>/dev/null || {
  printf 'overlay-master-mutate.sh: cannot create overlay dir: %s\n' "$OVERLAY_DIR" >&2
  exit 3
}

# Initialize overlay-master if absent (empty stub conforming to schema).
if [ ! -f "$OVERLAY_MASTER" ]; then
  if [ "$DRY_RUN" = "0" ] && [ "$RETRACT" = "0" ]; then
    printf '{}\n' > "$OVERLAY_MASTER"
  fi
fi

LOCK_FILE="$OVERLAY_DIR/.overlay-master.lock"

# ---- lock acquisition (re-exec under lockf) --------------------------------

if [ -z "${OVERLAY_MASTER_LOCKED:-}" ]; then
  export OVERLAY_MASTER_LOCKED=1
  # Forward the ORIGINAL argv verbatim + empty-safe (bash-3.2 indexed array): no
  # hand-rolled string rebuild, so each arg stays one token and a caller-supplied
  # --target 'Work/<spoke>/**' can no longer word-split / glob-expand against cwd
  # at the re-exec. overlay-master-mutate is not itself exposed to the
  # empty edge (PILLAR_COUNT=0 is rejected above) but adopts the same convergent
  # idiom as writer-reconciler + doc-amender for a single re-exec form.
  rc=0
  /usr/bin/lockf -k -t 0 "$LOCK_FILE" "$0" "${_BS_ORIG_ARGV[@]+"${_BS_ORIG_ARGV[@]}"}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" = "75" ]; then
      printf 'overlay-master-mutate.sh: lock contention on %s\n' "$LOCK_FILE" >&2
      exit 5
    fi
    exit "$rc"
  fi
  exit 0
fi

# ---- multi-pillar bundled mutation (under lock) -----------------------------

TMPFILE="$OVERLAY_MASTER.tmp.$$"

# Read current overlay-master (or empty stub) into the working JSON state.
if [ -s "$OVERLAY_MASTER" ]; then
  CURRENT=$(cat "$OVERLAY_MASTER")
else
  CURRENT='{}'
fi

# Validate current overlay-master parses as JSON.
if ! printf '%s' "$CURRENT" | jq empty >/dev/null 2>&1; then
  printf 'overlay-master-mutate.sh: current overlay-master is not valid JSON: %s\n' "$OVERLAY_MASTER" >&2
  exit 3
fi

# Load per-leaf UNION-strategy paths from merge-strategy-registry.
# Empty / missing registry -> degenerates to legacy REPLACE-everywhere (jq *)
# behavior. Surface registry-read failure as warning, not fatal.
UNION_PATHS_JSON='[]'
if [ -r "$MERGE_REGISTRY" ]; then
  UNION_RC=0
  # swallow-ok: reports=stderr the jq exit code is captured and a non-zero code prints the unreadable-registry line
  UNION_PATHS_JSON=$(jq -c '(.strategies // {}) | to_entries | map(select(.value == "union") | .key)' "$MERGE_REGISTRY" 2>/dev/null) || UNION_RC=$?
  if [ "$UNION_RC" -ne 0 ]; then
    printf 'overlay-master-mutate.sh: merge-strategy registry unreadable at %s (jq rc %s); union leaves degrade to REPLACE\n' "$MERGE_REGISTRY" "$UNION_RC" >&2
    UNION_PATHS_JSON='[]'
  fi
  [ -z "$UNION_PATHS_JSON" ] && UNION_PATHS_JSON='[]'
fi

# Apply each pillar payload as deep-merge into the pillar slot.
# Per R-52 collision tiebreaker: overlay wins on key collision.
#   1. Strip declared UNION leaves from payload (prevents jq `*` array-array
#      multiplication error on REPLACE path).
#   2. Default deep-merge stripped payload via jq `*`.
#   3. Walk declared UNION leaves; for each, compute per-leaf merge:
#      array+array -> concat + ORDER-PRESERVING dedup (opdedup; matches the read
#      side EXACTLY — NOT jq `unique`, which sorts); object+object ->
#      recursive merge; mixed/missing -> payload-wins fallback. Re-set into slot.
WORKING="$CURRENT"
i=1
for p in $PILLARS; do
  pf=$(printf '%s\n' $PAYLOAD_FILES | awk -v n="$i" 'NR==n')
  PAYLOAD=$(cat "$pf")
  EXISTING_PILLAR_VALUE=$(printf '%s' "$WORKING" | jq -c --arg p "$p" '.[$p] // null' 2>/dev/null)
  [ -z "$EXISTING_PILLAR_VALUE" ] && EXISTING_PILLAR_VALUE='null'
  WORKING=$(printf '%s' "$WORKING" | jq -c \
    --arg pillar "$p" \
    --argjson payload "$PAYLOAD" \
    --argjson existing_pillar "$EXISTING_PILLAR_VALUE" \
    --argjson union_paths "$UNION_PATHS_JSON" \
    '
      # Order-preserving dedup (first occurrence wins, input order retained) —
      # IDENTICAL to the read side (hooks/lib/foundation-overlay-load.sh). jq
      # `unique` SORTS (destroys path_routing.rules order); this does not.
      def opdedup: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
      (
        $union_paths
        | map(select(startswith($pillar + ".")))
        | map(split(".") | .[1:])
      ) as $union_sub_paths
      | (
          reduce $union_sub_paths[] as $sp ($payload;
            if (getpath($sp) != null) then delpaths([$sp]) else . end
          )
        ) as $stripped_payload
      | (
          if has($pillar) then
            .[$pillar] = (.[$pillar] * $stripped_payload)
          else
            .[$pillar] = $stripped_payload
          end
        ) as $merged
      | reduce $union_sub_paths[] as $sp ($merged;
          (($existing_pillar // {}) | getpath($sp)) as $e_val
          | ($payload | getpath($sp)) as $p_val
          | if $e_val == null and $p_val == null then
              .
            elif (($e_val | type) == "array") and (($p_val | type) == "array") then
              setpath([$pillar] + $sp; (($e_val + $p_val) | opdedup))
            elif (($e_val | type) == "object") and (($p_val | type) == "object") then
              setpath([$pillar] + $sp; ($e_val * $p_val))
            elif $p_val != null then
              setpath([$pillar] + $sp; $p_val)
            else
              setpath([$pillar] + $sp; $e_val)
            end
        )
    ' 2>/dev/null) || {
      printf 'overlay-master-mutate.sh: deep-merge failed for pillar %s\n' "$p" >&2
      rm -f "$TMPFILE"
      _append_failed_action_log "$p" "$pf" "deep-merge-failed"
      exit 6
    }
  i=$((i + 1))
done

# ---- retract-rule (under lock) ------------------------------------------------
#
# Exact-string removal of every .frontmatter.path_routing.rules element whose
# pattern equals RETRACT_PATTERN. The bare-array legacy shape is refused BEFORE
# anything is composed (the schema would reject the result, and the failed-
# action-log row of that rejection must not be written for a refusal). A run with
# no match writes nothing: no overlay file, no temp file, no action-log row. A
# match falls through to the shared tempfile / schema / dry-run / rename flow
# below, with PILLARS naming the one pillar touched for the failure row.
if [ "$RETRACT" = "1" ]; then
  if printf '%s' "$WORKING" | jq -e '(try .frontmatter.path_routing catch null) | type == "array"' >/dev/null 2>&1; then
    printf 'overlay-master-mutate.sh: --retract-rule: path_routing is a bare array (legacy shape the schema rejects); nothing retracted\n' >&2
    exit 4
  fi
  if ! printf '%s' "$WORKING" | jq -e --arg p "$RETRACT_PATTERN" \
      '[((try .frontmatter.path_routing.rules catch null) // []) | .[]? | select(type == "object" and .pattern == $p)] | length > 0' >/dev/null 2>&1; then
    printf "overlay-master-mutate.sh: no path_routing rule with pattern '%s'; nothing retracted\n" "$RETRACT_PATTERN" >&2
    exit 0
  fi
  RETRACTED=$(printf '%s' "$WORKING" | jq -c --arg p "$RETRACT_PATTERN" \
    '.frontmatter.path_routing.rules |= map(select((type == "object" and .pattern == $p) | not))')
  retract_rc=$?
  if [ "$retract_rc" -ne 0 ] || [ -z "$RETRACTED" ]; then
    printf 'overlay-master-mutate.sh: retract composition failed for pattern %s\n' "$RETRACT_PATTERN" >&2
    exit 6
  fi
  WORKING="$RETRACTED"
  PILLARS=" frontmatter"
fi

# Write composed JSON to tempfile (pretty-print for human inspection).
if ! printf '%s\n' "$WORKING" | jq '.' > "$TMPFILE" 2>/dev/null; then
  rm -f "$TMPFILE"
  printf 'overlay-master-mutate.sh: tempfile write failed: %s\n' "$TMPFILE" >&2
  exit 6
fi

# ---- JSON Schema 2020-12 validation against tempfile ------------------------

if ! python3 - "$SCHEMA" "$TMPFILE" <<'PY' 2>/dev/null
import json, sys, jsonschema
schema_path = sys.argv[1]
candidate_path = sys.argv[2]
with open(schema_path) as f:
    schema = json.load(f)
with open(candidate_path) as f:
    candidate = json.load(f)
validator = jsonschema.Draft202012Validator(schema)
errors = sorted(validator.iter_errors(candidate), key=lambda e: e.path)
if errors:
    for err in errors:
        print(f"schema-error: {list(err.path)}: {err.message}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
then
  printf 'overlay-master-mutate.sh: schema validation failed for tempfile\n' >&2
  rm -f "$TMPFILE"
  _append_failed_action_log "${PILLARS# }" "${PAYLOAD_FILES# }" "schema-validation-failed"
  exit 4
fi

# ---- dry-run exit gate ------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  printf 'overlay-master-mutate.sh: dry-run validation PASS; tempfile not committed: %s\n' "$TMPFILE" >&2
  rm -f "$TMPFILE"
  exit 0
fi

# ---- atomic swap ------------------------------------------------------------

if ! mv -f "$TMPFILE" "$OVERLAY_MASTER"; then
  rm -f "$TMPFILE"
  printf 'overlay-master-mutate.sh: atomic rename failed: %s -> %s\n' "$TMPFILE" "$OVERLAY_MASTER" >&2
  exit 6
fi

# ---- action-log append (one row per pillar mutated; R-37 atomic) -----------

SESSION_ID="${CLAUDE_SESSION_ID:-unknown-session}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$ACTION_LOG")" 2>/dev/null || true

# Retract: one row for the one rule pattern removed, then done (the per-pillar
# loop below reads payload files, which a retract does not have).
if [ "$RETRACT" = "1" ]; then
  ROW=$(jq -nc \
    --arg timestamp "$TS" \
    --arg kind "$KIND" \
    --arg proposed_by "$PROPOSED_BY" \
    --arg session_id "$SESSION_ID" \
    --arg target "$TARGET" \
    --arg pattern "$RETRACT_PATTERN" \
    '
      {
        timestamp: $timestamp,
        kind: $kind,
        proposed_by: $proposed_by,
        session_id: $session_id,
        target: ($target | if . == "" then $pattern else . end),
        validated_fields: { "frontmatter.path_routing.rules": { retracted: $pattern } },
        unregistered: false
      }
    ')
  retract_rc=$?
  if [ "$retract_rc" -ne 0 ] || [ -z "$ROW" ]; then
    printf 'overlay-master-mutate.sh: action-log row composition failed for retract\n' >&2
    exit 6
  fi
  if ! printf '%s\n' "$ROW" >> "$ACTION_LOG"; then
    printf 'overlay-master-mutate.sh: action-log append failed for retract\n' >&2
    exit 6
  fi
  printf "overlay-master-mutate.sh: retracted path_routing rule '%s'\n" "$RETRACT_PATTERN" >&2
  exit 0
fi

i=1
for p in $PILLARS; do
  pf=$(printf '%s\n' $PAYLOAD_FILES | awk -v n="$i" 'NR==n')
  # Per +: row shape is one row per pillar mutated.
  # validated_fields gets pillar name as key + the payload's top-level keys
  # as proof of accepted shape (downstream reconciliation reads this).
  PAYLOAD_KEYS=$(jq -c 'keys' "$pf" 2>/dev/null || echo '[]')
  ROW=$(jq -nc \
    --arg timestamp "$TS" \
    --arg kind "$KIND" \
    --arg proposed_by "$PROPOSED_BY" \
    --arg session_id "$SESSION_ID" \
    --arg target "$TARGET" \
    --arg pillar "$p" \
    --argjson payload_keys "$PAYLOAD_KEYS" \
    '
      {
        timestamp: $timestamp,
        kind: $kind,
        proposed_by: $proposed_by,
        session_id: $session_id,
        target: ($target | if . == "" then null else . end),
        validated_fields: { ($pillar): $payload_keys },
        unregistered: false
      }
      | with_entries(select(.value != null))
    ' 2>/dev/null)
  if [ -z "$ROW" ]; then
    printf 'overlay-master-mutate.sh: action-log row composition failed for pillar %s\n' "$p" >&2
    exit 6
  fi
  if ! printf '%s\n' "$ROW" >> "$ACTION_LOG"; then
    printf 'overlay-master-mutate.sh: action-log append failed for pillar %s\n' "$p" >&2
    exit 6
  fi
  i=$((i + 1))
done

printf 'overlay-master-mutate.sh: committed %s mutation(s) to %s\n' "$PILLAR_COUNT" "$OVERLAY_MASTER" >&2
exit 0
