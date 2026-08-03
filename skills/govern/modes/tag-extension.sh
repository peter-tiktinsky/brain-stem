#!/usr/bin/env bash
# modes/tag-extension.sh — handler for /govern register --kind tag-extension.
#
# Single-pillar mutation against tagging.taxonomy.dimension_prefixes per
# -orthogonal locks. No hook auto-fire — operator-driven mode.
#
# Sourced by process.sh. Exposes mode_propose() and mode_commit().
# bash 3.2 compatible.

mode_propose() {
  local dimension
  dimension=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dimension)    dimension="$2";    shift 2 ;;
      --proposed-by)  PROPOSED_BY="$2";  shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$dimension" ]; then
    printf 'tag-extension.mode_propose: --dimension <prefix> required\n' >&2
    return 2
  fi

  local proposed_by
  proposed_by="${PROPOSED_BY:-user-direct}"

  # dimension_prefixes is an ARRAY of prefix-slugs; the mode APPENDS the
  # new slug (the `--values` flag is dropped — no dimension_values leaf). The
  # declared ARRAY shape matches what the loader, guard, and audit-half all read;
  # a dict-shape emit dropped the foundation status/log/project prefixes.
  jq -nc \
    --arg dimension "$dimension" \
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
                dimension_prefixes: [ $dimension ]
              }
            },
            field_descriptions: {
              ($dimension): ("Allowed tag prefix #" + $dimension + "/* — appends the new prefix slug to the taxonomy dimension_prefixes set")
            }
          }
        ],
        notes: [
          "Tag-extension is single-pillar; no R-37 bundling.",
          "Write-time union (lib/overlay-master-mutate.sh): tagging.taxonomy.dimension_prefixes is declared UNION in lib/merge-strategy-registry.json — the new prefix slug is concat+deduped (order-preserving) against the existing overlay array.",
          "Read-time union (lib/foundation-overlay-load.sh): the foundation dimension_prefixes array and the adopter overlay array are unioned order-preserving (foundation-first) at read time, so the foundation prefixes (status/log/project) are PRESERVED and the adopter-declared new prefix is appended. R-52 collision (adopter shadows a foundation entry) requires per-entry `_override_reason: \"<text>\"` inline on the shadowing payload entry (canonical shape). The union is REAL on BOTH sides — the read-side loader unions the declared-union leaves, not merely the write-side library."
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
