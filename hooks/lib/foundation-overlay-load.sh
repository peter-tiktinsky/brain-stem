#!/usr/bin/env bash
# hooks/lib/foundation-overlay-load.sh — union-load primitive (R-52 READ path).
#
# Reads $CLAUDE_HOME/governance/foundation-master.json + overlay-master.json,
# performs R-52 collision tiebreaker check (overlay wins on collision IFF
# shadowing entry carries _override_reason), emits deep-merged JSON to stdout
# for hook consumption.
#
# amendment: top-level lib/ does NOT exist in brain-stem — this
# body lives at hooks/lib/foundation-overlay-load.sh, co-located with its
# primary consumer hooks/pre-write-guard.sh (the R-52 write-time probe; the
# no-flag consumer roster lives at the NO-FLAG CALL-SITE CONTRACT below).
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
# overlay entry (per verbatim).
#
# OVERLAY OPERATION SET — ADD + SUPERSEDE ONLY. There is no NULLIFY. An adopter
# overlay may ADD a key foundation does not declare, or SUPERSEDE a key it does
# declare with a FULL replacement value carrying `_override_reason`. It may NOT
# delete a foundation entry from the merged view: foundation conventions are
# immutable-by-design for adopters. A `null` overlay value is not a delete (the
# merge primitive has no delete) — it is REJECTED at the union block below.
# Array-of-object entity slots follow the R-52 ARRAY-ENTRY IDENTITY contract
# (R-52 rule_text + merge-strategy-registry.json `entity_identity_keys`):
# entries match on the slot's registry-declared identity key — unmatched = ADD;
# matched-and-differing (compared with `_override_reason` removed) = per-entry
# SUPERSEDE owing `_override_reason` on the entry; matched-and-identical =
# benign restatement; an omitted foundation identity = attempted REMOVAL
# (DENY — the merge primitive replaces arrays wholesale). An array-of-object
# slot with NO declared identity key is FAIL-CLOSED. Underscore-named keys are
# metadata UNLESS the slot's `underscore_entities` allowlist admits them as
# real entities (then they are gated like any entity).
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
  --force-override      Skip R-52 collision DENY for this invocation. Per:
                        no persistent disable; flag must be added per write.
  --collision-pillars   Comma-separated list of pillars to walk for R-52
                        collision detection. Default: all 8 (frontmatter,
                        tagging, naming, mandatory_files, doc_dependencies,
                        file_type_contracts, vault_writers, plans).

Exit codes:
  0  Success (union emitted; or fail-closed degraded fallback).
  1  R-52 violation — overlay shadows foundation without _override_reason.
  2  Usage error.
  3  Foundation read/parse error.
  5  jq failure (deep-merge, or R-52 collision-walk structural error — the
     walk is fail-closed: a jq raise is never swallowed into "no collisions").

Stderr:
  - R-52 DENY message (when exit 1)
  - Fail-closed warning (when overlay is invalid JSON; still exits 0)
  - Diagnostic messages

R-52 canonical shape (per-entry only; verbatim):
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

# Registry-declared R-52 entity metadata, shared by the collision walk AND the
# null-scan (which runs regardless of --force-override): per-slot array-entry
# identity keys, the underscore-entity allowlist, and the union-leaf roster.
# Missing/empty registry degrades each to its empty shape — identity keys then
# FAIL-CLOSED on any live array collision (by design: R-52 without its
# declarations must not fail open), underscore admission degrades to
# metadata-filter-everything (the pre-registry posture).
IDK_JSON=$(jq -c '(.entity_identity_keys // {}) | del(._description)' "$MERGE_REGISTRY" 2>/dev/null) || IDK_JSON='{}'
US_JSON=$(jq -c '(.underscore_entities // {}) | del(._description)' "$MERGE_REGISTRY" 2>/dev/null) || US_JSON='{}'
UNION_JSON=$(jq -c '[(.strategies // {}) | to_entries[] | select(.value=="union") | .key]' "$MERGE_REGISTRY" 2>/dev/null) || UNION_JSON='[]'
[ -z "$IDK_JSON" ] && IDK_JSON='{}'
[ -z "$US_JSON" ] && US_JSON='{}'
[ -z "$UNION_JSON" ] && UNION_JSON='[]'

if [ "$FORCE_OVERRIDE" != "1" ]; then
  DENIED_KEYS=""
  R52_TAB=$(printf '\t')

  # Declared-union leaves are excluded from the collision domain: union means
  # extend-not-shadow, so an overlay entry at a union leaf is an ADD by
  # construction — foundation declares the shape, the adopter extends it — and
  # no _override_reason is ever owed (R-52 operation_set.add). Sourced from the
  # SAME registry the merge block below reads (never a second hardcoded leaf
  # list): read + walk must agree or the walk denies what the merge sanctions.
  #
  # RESIDUAL LEDGER OF THIS WALK — (1) and (2) CLOSED by the array-identity
  # build; (3) remains dispositioned-by-ruling. None is silently unowned (each
  # behaviour is pinned by a RED-first fixture in the maintainer tree's test
  # bank, so it cannot drift silently):
  #   (1) CLOSED — array-valued SLOTS: the walk below dispatches on slot-node
  #       shape. An array-of-object slot iterates ENTRIES by the slot's
  #       registry-declared identity key (merge-strategy-registry.json
  #       `entity_identity_keys`; never a field name hardcoded here):
  #       unmatched = ADD; matched-and-differing (compared with
  #       `_override_reason` removed) = per-entry SUPERSEDE owing
  #       `_override_reason` on the entry; matched-and-identical = benign
  #       restatement; omitted foundation identity = attempted REMOVAL (DENY
  #       naming it — the merge primitive replaces arrays wholesale). A
  #       non-empty non-union foundation array under an UNDECLARED slot is
  #       FAIL-CLOSED (DENY at the slot naming the missing declaration), as is
  #       an entry that is not an identity-bearing object, a duplicate overlay
  #       identity, and a mixed-shape shadow (overlay array over a non-empty
  #       foundation object or vice versa — wholesale replacement is neither
  #       ADD nor per-entry SUPERSEDE; ruled fail-closed at this build).
  #   (2) CLOSED — underscore-named ENTITIES: the metadata filter admits keys
  #       the slot's `underscore_entities` registry allowlist declares as real
  #       entities (mandatory_files.mandates: _index_md, _memory_md_cap;
  #       file_type_contracts: _index.md), in the collision walk AND the
  #       null-scan below. Every other underscore key stays metadata.
  #   (3) COMPLIANCE-IMPOSSIBLE on supersede — RULED at the array-identity
  #       build, each leaf explicitly, NONE in the identity domain. The six
  #       reachable non-union NON-EMPTY array child keys in the shipped
  #       foundation are all SCALAR-value arrays (no entity objects), so
  #       identity-key matching cannot apply and per-entry _override_reason
  #       has no object to live on — each is EXCLUDED from
  #       entity_identity_keys with that reason:
  #         plans.lifecycle.status_enum        (string enum)     — excluded
  #         plans.lifecycle.terminal_status    (string enum)     — excluded
  #         plans.backlog_row.disposition_enum (string enum)     — excluded
  #         plans.backlog_row.required_fields  (string list)     — excluded
  #         plans.backlog_row.stale_advisory_days (number list)  — excluded
  #         plans.backlog_row.status_enum      (string enum)     — excluded
  #       Each keeps whole-leaf collision semantics: a supersede DENIES with
  #       --force-override as the only per-write path — posture UNCHANGED by
  #       the array-identity fix. Widening or relaxing any of the six remains
  #       an operator ruling, never a drive-by.
  #   Posture changes still ship only with an explicit operator ruling. Do
  #   not "fix" one in passing.
  #
  # NO-FLAG CALL-SITE CONTRACT (re-adjudicated at the array-identity build):
  # exactly TWO shipped consumers invoke this loader WITHOUT --force-override,
  # both purpose-built DETECTORS that exist to surface this walk's verdict —
  # pre-write-guard.sh's R-52 write-time probe, and install.sh's Step-13.9
  # apply-time probe (unflagged BY DESIGN in both). hooks/memory-
  # consolidation-run.sh, formerly a no-flag site, was OVERTURNED to
  # --force-override at that re-adjudication: the wider entity domain raises
  # deny frequency, and a policy deny was degrading the runner's
  # cap-governance READ — reads are not overlay writes, and R-52 detection
  # belongs to those two probes, not to read-path side effects. Every other
  # hook/skill read passes the flag. A NEW no-flag consumer inherits this
  # walk's DENY as a runtime failure mode and must handle exit 1 deliberately.
  R52_UNION_PATHS=$(jq -r '(.strategies // {}) | to_entries[] | select(.value=="union") | .key' "$MERGE_REGISTRY" 2>/dev/null || true)

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

      # Both FORMER walk arms — __top_level_keys__ (pillar value IS the dict
      # of entries, e.g. file_type_contracts; no intermediate slot key) and
      # normal-slot — share this ONE verdict program, so neither arm can be
      # fixed without the other by construction. It dispatches on overlay
      # slot-node SHAPE:
      #   object → per-key collision walk (the metadata filter admits the
      #            slot's underscore_entities allowlist entries as entities);
      #            emits K<TAB>key<TAB>has_reason
      #   array  → per-ENTRY walk on the registry-declared identity key;
      #            emits AS (supersede without reason) / AR (foundation entry
      #            omitted = removal) / AN (non-identity-bearing entry) /
      #            AD (duplicate overlay identity) / AF (undeclared array
      #            slot — FAIL-CLOSED)
      #   mixed  → AM (wholesale shape shadow — neither ADD nor per-entry
      #            SUPERSEDE; ruled fail-closed at the array-identity build)
      # Shadowing requires something to shadow: a key whose foundation value is
      # an EMPTY array/object is a declared-shape placeholder ("this slot is
      # yours to fill"), not a shadowed entity — the adopter's entry there is
      # an ADD. Key-presence alone ([] != null, {} != null) is NOT collision.
      # NO stderr suppression on this jq: a raise is a STRUCTURAL error and
      # exits 5 (fail-closed) — never silently an empty verdict set.
      if [ "$SLOT" = "__top_level_keys__" ]; then
        SLOT_PATH_PREFIX="${PILLAR}"
      else
        SLOT_PATH_PREFIX="${PILLAR}.${SLOT}"
      fi

      VERDICTS=$(printf '%s' "$OVERLAY_JSON" | jq -r \
          --argjson f "$FOUNDATION_JSON" --argjson us "$US_JSON" \
          --argjson idmap "$IDK_JSON" --argjson union "$UNION_JSON" \
          --arg p "$PILLAR" --arg s "$SLOT" --arg sp "$SLOT_PATH_PREFIX" '
        ( if $s == "__top_level_keys__" then (.[$p] // null)
          else ((.[$p] // {}) | if type == "object" then (.[$s] // null) else null end)
          end ) as $node
        | ( if $s == "__top_level_keys__" then ($f[$p] // null)
            else (($f[$p] // {}) | if type == "object" then (.[$s] // null) else null end)
            end ) as $fnode
        | (($us[$sp] // []) | if type == "array" then . else [] end) as $usallow
        | (($idmap[$sp] // "") | if type == "string" then . else "" end) as $idk
        | if $node == null then empty
          elif ($fnode != null)
               and (($fnode | type) == "array" or ($fnode | type) == "object")
               and (($fnode | length) > 0)
               and (($node | type) != ($fnode | type))
               and (($union | index($sp)) == null)
          then "AM\t" + ($node | type) + " over non-empty foundation " + ($fnode | type)
          elif ($node | type) == "object" then
            ( ($fnode | if type == "object" then . else {} end) as $fobj
              | $node | keys[]
              | . as $k
              | select(((startswith("_")) | not) or (($usallow | index($k)) != null))
              | ($fobj[$k] // null) as $fv
              | select(
                  $fv != null
                  and (
                    (($fv | type) == "array" or ($fv | type) == "object")
                    and (($fv | length) == 0)
                    | not
                  )
                )
              | "K\t" + $k + "\t"
                + (($node[$k] | if type == "object" then ((._override_reason // null) != null) else false end) | tostring)
            )
          elif ($node | type) == "array" then
            ( if (($union | index($sp)) != null) then empty
              else
                ($fnode | if type == "array" then . else [] end) as $farr
                | if ($farr | length) == 0 then empty
                  elif $idk == "" then
                    "AF\tno entity_identity_keys declaration for this array-of-object slot"
                  else
                    (
                      ( $node | to_entries[]
                        | select(((.value | type) != "object") or ((.value[$idk] // null) == null))
                        | "AN\tindex " + (.key | tostring) + " (entry is not an identity-bearing object)"
                      ),
                      (
                        [ $node[] | select(type == "object") | (.[$idk] // empty) | tostring ] as $oids
                        | (
                            ( $oids | group_by(.) | map(select(length > 1) | .[0]) | .[]
                              | "AD\t" + $idk + "=" + .
                            ),
                            ( $node[] | select((type == "object") and ((.[$idk] // null) != null)) | . as $e
                              | ($e[$idk] | tostring) as $eid
                              | ( [ $farr[] | select((type == "object") and ((.[$idk] // null) != null)
                                                    and ((.[$idk] | tostring) == $eid)) ]
                                  | (.[0] // null) ) as $fe
                              | select($fe != null)
                              | select((($e | del(._override_reason)) == ($fe | del(._override_reason))) | not)
                              | select(($e._override_reason // null) == null)
                              | "AS\t" + $idk + "=" + $eid
                            ),
                            ( $farr[] | select((type == "object") and ((.[$idk] // null) != null))
                              | (.[$idk] | tostring) as $fid
                              | select(($oids | index($fid)) == null)
                              | "AR\t" + $idk + "=" + $fid
                            )
                          )
                      )
                    )
                  end
              end
            )
          else empty
          end
      ') || {
        printf 'foundation-overlay-load.sh: R-52 collision-walk jq failure at %s — fail-closed (structural error, not a policy DENY).\n' "$SLOT_PATH_PREFIX" >&2
        exit 5
      }

      [ -z "$VERDICTS" ] && continue

      while IFS="$R52_TAB" read -r TAG A B; do
        [ -z "$TAG" ] && continue
        case "$TAG" in
          K)
            # Declared-union leaf → ADD by construction. Kept in shell so the
            # object path keeps its historical source (R52_UNION_PATHS).
            if printf '%s\n' "$R52_UNION_PATHS" | command grep -Fxq "${SLOT_PATH_PREFIX}.${A}"; then
              continue
            fi
            if [ "$B" != "true" ]; then
              DENIED_KEYS="${DENIED_KEYS}  - ${SLOT_PATH_PREFIX}.${A}\n"
            fi
            ;;
          AS) DENIED_KEYS="${DENIED_KEYS}  - ${SLOT_PATH_PREFIX}[${A}] (array-entry SUPERSEDE without _override_reason)\n" ;;
          AR) DENIED_KEYS="${DENIED_KEYS}  - ${SLOT_PATH_PREFIX}[${A}] (foundation entry omitted from overlay array — removal is not in the operation set; restate it)\n" ;;
          AN) DENIED_KEYS="${DENIED_KEYS}  - ${SLOT_PATH_PREFIX}[${A}]\n" ;;
          AD) DENIED_KEYS="${DENIED_KEYS}  - ${SLOT_PATH_PREFIX}[${A}] (duplicate identity in overlay array)\n" ;;
          AF) DENIED_KEYS="${DENIED_KEYS}  - ${SLOT_PATH_PREFIX} (${A} — FAIL-CLOSED)\n" ;;
          AM) DENIED_KEYS="${DENIED_KEYS}  - ${SLOT_PATH_PREFIX} (overlay ${A} — wholesale shape shadow is neither ADD nor per-entry SUPERSEDE)\n" ;;
        esac
      done <<EOF
$VERDICTS
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
      printf '  (a) add per-entry _override_reason: "<text>" to the shadowing overlay entry (per), OR\n'
      printf '  (b) pass --force-override for single-invocation bypass (per-write; no persistent disable per).\n'
      printf 'Array-of-object slots match entries on the registry-declared identity key\n'
      printf '(merge-strategy-registry.json entity_identity_keys): unmatched = ADD; matched-and-differing =\n'
      printf 'per-entry SUPERSEDE owing _override_reason ON the entry; an omitted foundation identity is a\n'
      printf 'removal (not in the operation set) — restate the foundation entry to comply.\n'
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
# slots `_entity_slots_for` declares for the R-52 walk. Underscore-named keys a
# slot's `underscore_entities` allowlist declares as real entities are
# protected here too — entity classification is CONSISTENT with the collision
# walk above; every other underscore key stays metadata (skipped).
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
  NULL_PATHS_JSON=$(printf '%s' "$OVERLAY_JSON" | jq -c --argjson map "$NULL_SCAN_MAP" --argjson us "$US_JSON" '
    . as $o
    | [ $map[]
        | . as $m
        | (if $m.s == "__top_level_keys__" then $m.p else ($m.p + "." + $m.s) end) as $sp
        | (($us[$sp] // []) | if type == "array" then . else [] end) as $usallow
        | (($o[$m.p] // null) | if type == "object" then . else null end) as $pil
        | (if $m.s == "__top_level_keys__" then $pil
           elif $pil == null then null
           else ($pil[$m.s] // null) end) as $node
        | ($node | if type == "object" then . else {} end)
        | to_entries[]
        | select(.value == null)
        | .key as $ek
        | select((($ek | startswith("_")) | not) or (($usallow | index($ek)) != null))
        | if $m.s == "__top_level_keys__" then [$m.p, $ek] else [$m.p, $m.s, $ek] end
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
