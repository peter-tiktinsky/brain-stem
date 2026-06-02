#!/usr/bin/env bash
# modes/tag-extension.sh — handler for /govern register --kind tag-extension.
#
# Single-pillar mutation against tagging.taxonomy.dimension_prefixes.
# No hook auto-fire — operator-driven mode.
#
# Sourced by process.sh. Exposes mode_propose() and mode_commit().
# bash 3.2 compatible.

mode_propose() {
  local dimension values
  dimension=""
  values=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dimension)    dimension="$2";    shift 2 ;;
      --values)       values="$2";       shift 2 ;;
      --proposed-by)  PROPOSED_BY="$2";  shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$dimension" ]; then
    printf 'tag-extension.mode_propose: --dimension <prefix> required\n' >&2
    return 2
  fi
  if [ -z "$values" ]; then
    printf 'tag-extension.mode_propose: --values <comma-list> required\n' >&2
    return 2
  fi

  local proposed_by
  proposed_by="${PROPOSED_BY:-user-direct}"

  # Convert "v1,v2,v3" → ["v1","v2","v3"] via jq.
  local values_array
  values_array=$(printf '%s' "$values" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')

  jq -nc \
    --arg dimension "$dimension" \
    --argjson values "$values_array" \
    --arg proposed_by "$proposed_by" \
    '
      {
        kind: "tag-extension",
        target: $dimension,
        proposed_by: $proposed_by,
        pillars: [
          {
            pillar: "tagging",
            payload: {
              taxonomy: {
                dimension_prefixes: {
                  ($dimension): $values
                }
              }
            },
            field_descriptions: {
              ($dimension): ("Allowed tag values under #" + $dimension + "/* — extends the taxonomy enum")
            }
          }
        ],
        notes: [
          "Tag-extension is single-pillar; no R-37 bundling.",
          "Write-time merge (lib/overlay-master-mutate.sh): per-leaf strategy declared in lib/merge-strategy-registry.json. tagging.taxonomy.dimension_prefixes is declared UNION: array-shape payloads concat+dedup against existing overlay state; dict-shape payloads fall through to object recursive merge (legacy fixture shape).",
          "Read-time R-52 collision (lib/foundation-overlay-load.sh): if dimension EXISTS in foundation-master.tagging.taxonomy.dimension_prefixes AND adopter overlay declares the same dimension, overlay wins (adopter shadows foundation). Shadowing requires per-entry `_override_reason: \"<text>\"` inline on the shadowing payload entry (canonical shape). Foundation+overlay UNION semantics at the dimension_prefixes leaf are produced by the helper at read time, not by the library at write time."
        ]
      }
    '
}

mode_commit() {
  local proposal="$1"
  shift || true

  if [ ! -r "$proposal" ]; then
    printf 'tag-extension.mode_commit: proposal file not readable: %s\n' "$proposal" >&2
    return 2
  fi

  local target proposed_by pillar_count
  target=$(jq -r '.target' "$proposal")
  proposed_by=$(jq -r '.proposed_by // "user-direct"' "$proposal")
  pillar_count=$(jq '.pillars | length' "$proposal")

  if [ -z "$target" ] || [ "$target" = "null" ]; then
    printf 'tag-extension.mode_commit: proposal missing .target\n' >&2
    return 2
  fi
  if [ "$pillar_count" -lt 1 ]; then
    printf 'tag-extension.mode_commit: proposal .pillars[] is empty\n' >&2
    return 2
  fi

  local tmpdir
  tmpdir=$(mktemp -d -t govern-register-tag.XXXXXX) || {
    printf 'tag-extension.mode_commit: tempdir creation failed\n' >&2
    return 3
  }
  trap 'rm -rf "$tmpdir"' RETURN

  local i=0
  local lib_args=""
  while [ "$i" -lt "$pillar_count" ]; do
    local p payload pf
    p=$(jq -r ".pillars[$i].pillar" "$proposal")
    payload=$(jq -c ".pillars[$i].payload" "$proposal")
    pf="$tmpdir/payload-$i.json"
    printf '%s\n' "$payload" > "$pf"
    lib_args="$lib_args --pillar $p --payload-file $pf"
    i=$((i + 1))
  done

  # shellcheck disable=SC2086
  "$LIB_MUTATE" \
    $lib_args \
    --kind tag-extension \
    --target "$target" \
    --proposed-by "$proposed_by"
  return $?
}
