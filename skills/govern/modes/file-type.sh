#!/usr/bin/env bash
# modes/file-type.sh — Class B/C handler for /govern register --kind file-type.
#
# Class B: new vault-root file; Class C: new file-type
# in existing folder + subfolder semantic divergence. R-37 atomic
# across frontmatter.types + file_type_contracts.<type-slug>.
#
# Sourced by process.sh. Exposes mode_propose() and mode_commit().
# bash 3.2 compatible.

mode_propose() {
  local name contract
  name=""
  contract=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)         name="$2";         shift 2 ;;
      --contract)     contract="$2";     shift 2 ;;
      --proposed-by)  PROPOSED_BY="$2";  shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$name" ]; then
    printf 'file-type.mode_propose: --name <type-slug> required\n' >&2
    return 2
  fi

  local proposed_by
  proposed_by="${PROPOSED_BY:-user-direct}"

  # Contract payload: either read from --contract <path> or render a
  # minimum-viable stub. The MV stub is what most propose-time calls land
  # on; the operator validates per-field; for richer contracts the operator
  # can pass --contract <path-to-fully-authored.json>.
  local contract_json
  if [ -n "$contract" ]; then
    if [ ! -r "$contract" ]; then
      printf 'file-type.mode_propose: --contract file not readable: %s\n' "$contract" >&2
      return 2
    fi
    if ! jq empty "$contract" >/dev/null 2>&1; then
      printf 'file-type.mode_propose: --contract file not valid JSON: %s\n' "$contract" >&2
      return 2
    fi
    contract_json=$(cat "$contract")
  else
    contract_json=$(jq -nc --arg name "$name" '
      {
        "$schema": "schemas/file-type-contract-schema.json",
        type: $name,
        frontmatter: {
          required: ["type", "tags", "created", "updated"],
          enums: { type: [$name] }
        },
        body: { free_form: true }
      }
    ')
  fi

  jq -nc \
    --arg name "$name" \
    --arg proposed_by "$proposed_by" \
    --argjson contract "$contract_json" \
    '
      # Derive frontmatter type-entry shape from the contract — matches
      # foundation .frontmatter.types.<slug> shape: {required, optional, tier}.
      # Migrated from array
      # shape `{types: [<slug>]}` to object shape `{types: {<slug>: <entry>}}`
      # so /govern register overlay payloads align with foundation pillar
      # shape end-to-end. Tier defaults to "standard"; operator may override.
      ($contract.frontmatter.required // ["type", "tags"]) as $req
      | ($contract.frontmatter.optional // [])              as $opt
      | ($contract.frontmatter.tier     // "standard")      as $tier
      | {
        kind: "file-type",
        target: $name,
        proposed_by: $proposed_by,
        pillars: [
          {
            pillar: "frontmatter",
            payload: { types: { ($name): {required: $req, optional: $opt, tier: $tier} } },
            field_descriptions: {
              ($name): ("Add type entry \"" + $name + "\" under frontmatter.types as {required, optional, tier}; pre-write-guard R-32 + Branch #1 Class C anchor on this dict")
            }
          },
          {
            pillar: "file_type_contracts",
            payload: { ($name): $contract },
            field_descriptions: {
              ($name): ("File-type contract for \"" + $name + "\" — frontmatter required fields + enums + body shape. Defaults to a minimum-viable stub; operator extends per-field.")
            }
          }
        ],
        notes: [
          "R-37 atomic across both pillars — frontmatter.types and file_type_contracts.<type-slug> bundle in a single library invocation.",
          "frontmatter.types entry derives {required, optional, tier} from the contract.frontmatter; remaining contract content (enums, body shape) lives in file_type_contracts.",
          "If --contract not supplied, the proposal carries a MV stub: required = [type, tags, created, updated], optional = [], tier = standard, free_form body. Operator extends per-field before commit."
        ]
      }
    '
}

mode_commit() {
  local proposal="$1"
  shift || true

  if [ ! -r "$proposal" ]; then
    printf 'file-type.mode_commit: proposal file not readable: %s\n' "$proposal" >&2
    return 2
  fi

  local target proposed_by pillar_count
  target=$(jq -r '.target' "$proposal")
  proposed_by=$(jq -r '.proposed_by // "user-direct"' "$proposal")
  pillar_count=$(jq '.pillars | length' "$proposal")

  if [ -z "$target" ] || [ "$target" = "null" ]; then
    printf 'file-type.mode_commit: proposal missing .target\n' >&2
    return 2
  fi
  if [ "$pillar_count" -lt 1 ]; then
    printf 'file-type.mode_commit: proposal .pillars[] is empty\n' >&2
    return 2
  fi

  local tmpdir
  tmpdir=$(mktemp -d -t govern-register-filetype.XXXXXX) || {
    printf 'file-type.mode_commit: tempdir creation failed\n' >&2
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
    --kind file-type \
    --target "$target" \
    --proposed-by "$proposed_by"
  return $?
}
