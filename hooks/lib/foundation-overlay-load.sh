#!/usr/bin/env bash
# hooks/lib/foundation-overlay-load.sh — union-load primitive (R-52 READ path).
#
# Reads $CLAUDE_HOME/governance/foundation-master.json + overlay-master.json,
# performs R-52 collision tiebreaker check (overlay wins on collision IFF
# shadowing entry carries _override_reason), emits deep-merged JSON to stdout
# for hook consumption.
#
# This body lives at hooks/lib/foundation-overlay-load.sh, co-located with its
# consumer hooks/pre-write-guard.sh (the R-52 single call-site at :91/:1081).
# Hook-portability: NO $HOME/.claude literal in resolution — the
# defaults resolve via $CLAUDE_HOME (set by hooks/lib/paths.sh; falls back to
# $HOME/.claude only as the install-convention base).
#
# R-52 contract verbatim (governance/_index.json):
#   When adopter Layer-3 overlay and foundation canonical both declare the
#   same rule ID / extensible entry kind: adopter Layer-3 SHADOWS foundation
#   (adopter wins). Adopter MUST carry `_override_reason` (free-text,
#   mandatory) on every shadowing entry. Per-write `--force-override` flag
#   bypasses DENY for a single write.
#
# Canonical shape: `_override_reason` is a PER-ENTRY field on the shadowing
# overlay entry.
#
# OVERLAY OPERATION SET — ADD + SUPERSEDE ONLY. There is no NULLIFY. An adopter
# overlay may ADD a key foundation does not declare, or SUPERSEDE a key it does
# declare with a FULL replacement value carrying `_override_reason`. It may NOT
# delete a foundation entry from the merged view: foundation conventions are
# immutable-by-design for adopters. A `null` overlay value is not a delete (the
# merge primitive has no delete) — it is REJECTED at the union block below.
# Retiring a foundation convention is a maintainer-side source edit; the
# `frontmatter.retired_types` tombstone is foundation-authored and
# overlay-extensible in the ADD direction only.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`, no `${var,,}`).
# No file locks (read-only helper; mutate-side library handles locks).

set -u

# ---- Defaults (Hook-portability: resolve via $CLAUDE_HOME, no $HOME/.claude literal) ---

_BS_CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
FOUNDATION_PATH="${FOUNDATION_MASTER_PATH:-$_BS_CLAUDE_HOME/governance/foundation-master.json}"
OVERLAY_PATH="${OVERLAY_MASTER_PATH:-$_BS_CLAUDE_HOME/governance/overlay-master.json}"
QUERY=""
FORCE_OVERRIDE=0
# Per-pillar R-52 walk scope. Default = all 8 overlay pillars. Operator can
# narrow via --collision-pillars <comma-sep> for testing/staged rollout.
COLLISION_PILLARS="frontmatter,tagging,naming,mandatory_files,doc_dependencies,file_type_contracts,vault_writers,plans"

# Per-leaf merge-strategy registry (read-side union). Declared UNION
# leaves get an ORDER-PRESERVING concat+dedup in place of the bare `. * $o`
# array-REPLACE below; every other leaf keeps deep-merge REPLACE semantics.
# Default: the sibling hooks/lib/merge-strategy-registry.json (co-located with
# this loader AND overlay-master-mutate.sh — the WRITE consumer of the SAME
# registry; read + write must agree). Env override $MERGE_REGISTRY for fixture
# testing. Empty / missing registry -> degrades to legacy REPLACE-everywhere.
if [ -z "${MERGE_REGISTRY:-}" ]; then
  _BS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd 2>/dev/null || printf '%s' "$_BS_CLAUDE_HOME/hooks/lib")
  MERGE_REGISTRY="$_BS_SCRIPT_DIR/merge-strategy-registry.json"
fi

# ---- Usage ------------------------------------------------------------------

usage() {
  cat <<EOF
foundation-overlay-load.sh — union-load helper with R-52 enforcement.

Usage:
  foundation-overlay-load.sh \\
      [--foundation-path <path>] \\
      [--overlay-path <path>] \\
      [--query <jq-filter>] \\
      [--force-override] \\
      [--collision-pillars <comma-sep>]

Args:
  --foundation-path     Foundation bundle path. Default: \$FOUNDATION_MASTER_PATH
                        or \$CLAUDE_HOME/governance/foundation-master.json.
  --overlay-path        Overlay path. Default: \$OVERLAY_MASTER_PATH or
                        \$CLAUDE_HOME/governance/overlay-master.json.
  --query               Optional jq filter applied to union JSON before stdout
                        emission. Default: emit full union.
  --force-override      Skip R-52 collision DENY for this invocation.
                        No persistent disable; flag must be added per write.
  --collision-pillars   Comma-separated list of pillars to walk for R-52
                        collision detection. Default: all 8 (frontmatter,
                        tagging, naming, mandatory_files, doc_dependencies,
                        file_type_contracts, vault_writers, plans).

Exit codes:
  0  Success (union emitted; or fail-closed degraded fallback).
  1  R-52 violation — overlay shadows foundation without _override_reason.
  2  Usage error.
  3  Foundation read/parse error.
  5  Deep-merge failed (jq error).

Stderr:
  - R-52 DENY message (when exit 1)
  - Fail-closed warning (when overlay is invalid JSON; still exits 0)
  - Diagnostic messages

R-52 canonical shape (per-entry only):
  Shadowing overlay entries MUST carry \`_override_reason: "<text>"\` field
  directly on the entry, e.g. \$overlay.frontmatter.types.<slug>._override_reason.
  Absence DENIES (or fall-back to \`--force-override\` for per-write bypass).
EOF
}

# ---- Arg parse --------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --foundation-path)    FOUNDATION_PATH="$2"; shift 2 ;;
    --overlay-path)       OVERLAY_PATH="$2"; shift 2 ;;
    --query)              QUERY="$2"; shift 2 ;;
    --force-override)     FORCE_OVERRIDE=1; shift ;;
    --collision-pillars)  COLLISION_PILLARS="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *) printf 'foundation-overlay-load.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- Read foundation (required) ---------------------------------------------

if [ ! -r "$FOUNDATION_PATH" ]; then
  printf 'foundation-overlay-load.sh: foundation not readable: %s\n' "$FOUNDATION_PATH" >&2
  exit 3
fi
FOUNDATION_JSON=$(cat "$FOUNDATION_PATH")
if ! printf '%s' "$FOUNDATION_JSON" | jq empty >/dev/null 2>&1; then
  printf 'foundation-overlay-load.sh: foundation not valid JSON: %s\n' "$FOUNDATION_PATH" >&2
  exit 3
fi

# ---- Read overlay (optional; fail-closed on parse failure) ------------------

OVERLAY_JSON='{}'
if [ -r "$OVERLAY_PATH" ]; then
  OVERLAY_RAW=$(cat "$OVERLAY_PATH")
  if printf '%s' "$OVERLAY_RAW" | jq empty >/dev/null 2>&1; then
    OVERLAY_JSON="$OVERLAY_RAW"
  else
    printf 'foundation-overlay-load.sh: overlay invalid JSON at %s; falling back to foundation-only view (degraded but safe).\n' "$OVERLAY_PATH" >&2
    OVERLAY_JSON='{}'
  fi
fi

# ---- R-52 collision check (per-pillar walk) ---------------------------------
#
# Per-pillar entity-slot registry. For each pillar, lists the SUB-KEYS where
# overlay entries are treated as ENTITY-level R-52-collision-checkable. Other
# sub-keys (scalar config, metadata) are not in the collision domain — they
# overlay-replace under deep-merge.
_entity_slots_for() {
  case "$1" in
    frontmatter)         printf 'types\nretired_types\npath_routing\nrules\n' ;;
    tagging)             printf 'rules\n' ;;
    naming)              printf 'rules\n' ;;
    mandatory_files)     printf 'rules\nmandates\n' ;;
    doc_dependencies)    printf 'entries\nentities\n' ;;
    file_type_contracts) printf '__top_level_keys__\n' ;;
    vault_writers)       : ;;  # No entity-level collision domain (scalar config only).
    plans)               printf 'lifecycle\nbacklog_row\n' ;;
    *)                   : ;;  # Unknown pillar: silently skip (forward-compatible).
  esac
}

if [ "$FORCE_OVERRIDE" != "1" ]; then
  DENIED_KEYS=""

  # Iterate selected pillars (default = all 8; --collision-pillars narrows).
  IFS_SAVED="$IFS"
  IFS=','
  # shellcheck disable=SC2086
  set -- $COLLISION_PILLARS
  IFS="$IFS_SAVED"

  for PILLAR in "$@"; do
    [ -z "$PILLAR" ] && continue
    SLOTS=$(_entity_slots_for "$PILLAR")
    [ -z "$SLOTS" ] && continue

    while IFS= read -r SLOT; do
      [ -z "$SLOT" ] && continue

      # Special token: walk overlay top-level keys of the pillar object
      # directly (file_type_contracts shape: pillar value IS a dict of
      # contract entries; no intermediate slot key).
      if [ "$SLOT" = "__top_level_keys__" ]; then
        COLLISIONS=$(printf '%s' "$OVERLAY_JSON" | jq -r --argjson f "$FOUNDATION_JSON" --arg p "$PILLAR" '
          (.[$p] // {}) | keys[]?
          | select(startswith("_") | not)
          | select($f[$p][.] != null)
        ' 2>/dev/null)
        SLOT_PATH_PREFIX="${PILLAR}"
      else
        COLLISIONS=$(printf '%s' "$OVERLAY_JSON" | jq -r --argjson f "$FOUNDATION_JSON" --arg p "$PILLAR" --arg s "$SLOT" '
          (.[$p][$s] // {}) | keys[]?
          | select(startswith("_") | not)
          | select($f[$p][$s][.] != null)
        ' 2>/dev/null)
        SLOT_PATH_PREFIX="${PILLAR}.${SLOT}"
      fi

      [ -z "$COLLISIONS" ] && continue

      while IFS= read -r ck; do
        [ -z "$ck" ] && continue
        # Canonical shape: per-entry `_override_reason` on the shadowing
        # overlay entry.
        if [ "$SLOT" = "__top_level_keys__" ]; then
          HAS_REASON=$(printf '%s' "$OVERLAY_JSON" | jq -r --arg p "$PILLAR" --arg k "$ck" '
            (.[$p][$k]
             | if type == "object" then ._override_reason else null end
            ) // null
            | . != null
          ' 2>/dev/null)
        else
          HAS_REASON=$(printf '%s' "$OVERLAY_JSON" | jq -r --arg p "$PILLAR" --arg s "$SLOT" --arg k "$ck" '
            (.[$p][$s][$k]
             | if type == "object" then ._override_reason else null end
            ) // null
            | . != null
          ' 2>/dev/null)
        fi
        if [ "$HAS_REASON" != "true" ]; then
          DENIED_KEYS="${DENIED_KEYS}  - ${SLOT_PATH_PREFIX}.${ck}\n"
        fi
      done <<EOF
$COLLISIONS
EOF
    done <<EOF2
$SLOTS
EOF2
  done

  if [ -n "$DENIED_KEYS" ]; then
    {
      printf 'foundation-overlay-load.sh: R-52 violation — overlay shadows foundation entries without _override_reason:\n'
      printf '%b' "$DENIED_KEYS"
      printf 'To resolve, either:\n'
      printf '  (a) add per-entry _override_reason: "<text>" to the shadowing overlay entry, OR\n'
      printf '  (b) pass --force-override for single-invocation bypass (per-write; no persistent disable).\n'
    } >&2
    exit 1
  fi
fi

# ---- Null-contract rejection: the overlay operation set is ADD + SUPERSEDE --
# ---- ONLY — a null-valued entry is REJECTED, never a NULLIFY ----------------
#
# jq's `. * $o` recursive object-merge CANNOT delete a key. An overlay entry
# written as `null` therefore does NOT remove the foundation entry — it merges
# a key whose VALUE is null. Downstream, that key is still ACCEPTED (it is
# present in `keys`) while every contract read under it (required[], tier,
# expected_path, …) yields nothing: an accepted entry with no contract, which
# is strictly worse than the un-attempted override. Foundation conventions are
# immutable-by-design for adopters, so a null-valued overlay entity entry is
# REJECTED here — reported LOUD on stderr naming each path, then DROPPED from
# the overlay before the merge so the foundation entry stands. Well-formed
# overlay entries are untouched, and the drop is scoped to the SAME entity
# slots `_entity_slots_for` declares for the R-52 walk.
#
# This runs REGARDLESS of --force-override: that flag bypasses the R-52
# collision DENY (a policy decision), not structural corruption of the merged
# view. Cost in the clean case is ONE extra jq pass; the report pass runs only
# when a null entry is actually found.
NULL_SCAN_MAP='['
_NSM_FIRST=1
_NSM_IFS_SAVED="$IFS"
IFS=','
# shellcheck disable=SC2086
set -- $COLLISION_PILLARS
IFS="$_NSM_IFS_SAVED"
for PILLAR in "$@"; do
  [ -z "$PILLAR" ] && continue
  SLOTS=$(_entity_slots_for "$PILLAR")
  [ -z "$SLOTS" ] && continue
  while IFS= read -r SLOT; do
    [ -z "$SLOT" ] && continue
    [ "$_NSM_FIRST" = "1" ] || NULL_SCAN_MAP="${NULL_SCAN_MAP},"
    _NSM_FIRST=0
    NULL_SCAN_MAP="${NULL_SCAN_MAP}{\"p\":\"${PILLAR}\",\"s\":\"${SLOT}\"}"
  done <<NSM_EOF
$SLOTS
NSM_EOF
done
NULL_SCAN_MAP="${NULL_SCAN_MAP}]"

NULL_PATHS_JSON='[]'
if [ "$NULL_SCAN_MAP" != "[]" ]; then
  NULL_PATHS_JSON=$(printf '%s' "$OVERLAY_JSON" | jq -c --argjson map "$NULL_SCAN_MAP" '
    . as $o
    | [ $map[]
        | . as $m
        | (($o[$m.p] // null) | if type == "object" then . else null end) as $pil
        | (if $m.s == "__top_level_keys__" then $pil
           elif $pil == null then null
           else ($pil[$m.s] // null) end) as $node
        | ($node | if type == "object" then . else {} end)
        | to_entries[]
        | select(.value == null)
        | select(.key | startswith("_") | not)
        | if $m.s == "__top_level_keys__" then [$m.p, .key] else [$m.p, $m.s, .key] end
      ]
  ' 2>/dev/null) || NULL_PATHS_JSON='[]'
  [ -z "$NULL_PATHS_JSON" ] && NULL_PATHS_JSON='[]'
fi

if [ "$NULL_PATHS_JSON" != "[]" ]; then
  NULL_REPORT=$(printf '%s' "$NULL_PATHS_JSON" | jq -r '.[] | "  - " + join(".")' 2>/dev/null)
  {
    printf 'foundation-overlay-load.sh: null-valued overlay entries REJECTED (not merged):\n'
    printf '%s\n' "$NULL_REPORT"
    printf 'The overlay operation set is ADD + SUPERSEDE only — a null value cannot NULLIFY a\n'
    printf 'foundation entry (object-merge keeps the key and drops its contract, leaving an\n'
    printf 'ACCEPTED entry with no contract). The listed entries are dropped for this load and\n'
    printf 'the foundation entry stands. Remove them from %s; to change a foundation entry,\n' "$OVERLAY_PATH"
    printf 'SUPERSEDE it with a full replacement entry carrying _override_reason (R-52).\n'
  } >&2
  OVERLAY_CLEANED=$(printf '%s' "$OVERLAY_JSON" | jq -c --argjson p "$NULL_PATHS_JSON" 'delpaths($p)' 2>/dev/null)
  if [ -n "$OVERLAY_CLEANED" ]; then
    OVERLAY_JSON="$OVERLAY_CLEANED"
  else
    printf 'foundation-overlay-load.sh: null-entry strip failed; falling back to the foundation-only view (degraded but safe).\n' >&2
    OVERLAY_JSON='{}'
  fi
fi

# ---- Registry-driven union merge: overlay wins per R-52, with an ----
# ---- ORDER-PRESERVING concat+dedup on every declared-union leaf -------------
#
# The bare `. * $o` recursive object-merge REPLACES arrays, so every declared-
# union leaf (merge-strategy-registry.json .strategies[*]=="union") was blindly
# replaced instead of unioned — bricking an adopter's first non-empty extension
# (e.g. /govern register --kind tag-extension dropped the foundation
# status/log/project prefixes). Consume the registry and, for each declared-
# union leaf, produce a FOUNDATION-FIRST order-preserving concat+dedup (NOT jq
# `unique`, which sorts). Dict-shape union leaves fall back to object-recursive-
# merge (registry _shape_handling; preserves the baseline fixture shape);
# mixed shape (array one side / dict the other) resolves payload(overlay)-wins.
# Every non-union leaf keeps `. * $o` REPLACE semantics. The dedup matches the
# WRITE side (overlay-master-mutate.sh) EXACTLY so read + write agree.
UNION_PATHS_JSON='[]'
if [ -r "$MERGE_REGISTRY" ]; then
  UNION_PATHS_JSON=$(jq -c '(.strategies // {}) | to_entries | map(select(.value == "union") | .key)' "$MERGE_REGISTRY" 2>/dev/null) || UNION_PATHS_JSON='[]'
  [ -z "$UNION_PATHS_JSON" ] && UNION_PATHS_JSON='[]'
fi

UNION_JSON=$(jq -n \
  --argjson foundation "$FOUNDATION_JSON" \
  --argjson overlay "$OVERLAY_JSON" \
  --argjson union_paths "$UNION_PATHS_JSON" \
  '
    # Order-preserving dedup: first occurrence wins, input order retained.
    # Handles scalar AND object array members (any(.[]; . == $x) equality).
    def opdedup: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    ($union_paths | map(split("."))) as $usp
    | ($foundation * $overlay) as $base
    | reduce $usp[] as $sp ($base;
        ($foundation | getpath($sp)) as $f
        | ($overlay | getpath($sp)) as $o
        | if ($f == null) and ($o == null) then .
          elif (($f | type) == "array") and (($o | type) == "array") then
            setpath($sp; (($f + $o) | opdedup))
          elif (($f | type) == "object") and (($o | type) == "object") then
            setpath($sp; ($f * $o))
          elif $o != null then
            setpath($sp; $o)
          else
            setpath($sp; $f)
          end
      )
  ' 2>/dev/null)
if [ -z "$UNION_JSON" ]; then
  printf 'foundation-overlay-load.sh: deep-merge failed\n' >&2
  exit 5
fi

# ---- Emit ------------------------------------------------------------------

if [ -n "$QUERY" ]; then
  printf '%s' "$UNION_JSON" | jq "$QUERY"
else
  printf '%s' "$UNION_JSON" | jq '.'
fi
