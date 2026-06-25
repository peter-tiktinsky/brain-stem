#!/usr/bin/env bash
# modes/writer.sh — Class D handler for /govern register --kind writer.
# Per Session 5..(writer-reference frontmatter contract; one file
# per writer-skill; destinations[] carries per-flow shape) + Session 5
# (Class D auto-suggestion; shared overlay slot with wizard +
# user-direct invocation). Writer mode is STRUCTURALLY DISTINCT from
# folder/file-type/tag-extension:
#   - Canonical declaration = `<vault-root>/Vault Writers/<slug>.md`
#     (writer-reference file; standard atomic write through pre-write-guard.sh
#     + post-write-verify.sh)
#   - overlay-master.vault_writers slot is for processing-defaults overrides
#     ONLY (rare; not minimum-viable T-10 scope). Library is invoked with an
#     empty {} payload purely for the atomic action-log row append under the
#     same lockf serialization the other modes use — ensuring lockstep
#     causality between writer-reference file existence and action-log row.
#   - Schema validation (writer-reference frontmatter) is enforced by
#     pre-write-guard.sh branch #3 (Branch #3) downstream against the
#     SHIPPED contract `governance/file-type-contracts/vault-writer.md.json`
#     (pillar 6 SHAPE; in foundation-manifest.json::files[], delivered to
#     $CLAUDE_HOME/governance/file-type-contracts/ at install Step 8.5). The
#     skill trusts the hook; no re-validation here. NOTE:
#     the legacy `schemas/vault-schema.json` was DISSOLVED at T-4 (types
#     absorbed into the pillars); the Output Contract for Vault Writers/ writes
#     resolves against the shipped vault-writer.md.json — NOT the dissolved
#     schema. The regression internal/tests/ac-vault-writer-deny-regression.sh
#     drives invalid frontmatter through the production bare-path hook chain and
#     asserts a DENY, so the Output Contract is GATE-backed, not write-and-hope.
# Sourced by process.sh. Exposes mode_propose() and mode_commit().
# bash 3.2 compatible.

# Reuse the collision-safe cwd->spoke resolver + --project override validator
# (single SoT lives in new-plan/lib; the writer mode stamps the SAME
# registry-resolved spoke key, never a bare basename). Resolved relative to this
# handler's repo root.
_WRITER_MODE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$_WRITER_MODE_DIR/../../new-plan/lib/spoke-resolve.sh"

mode_propose() {
  local writer_name writer_kind writer_subtype writer_skill project
  writer_name=""
  writer_kind=""
  writer_subtype=""
  writer_skill=""
  project=""
  local project_explicit=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --writer-name)     writer_name="$2";     shift 2 ;;
      --writer-kind)     writer_kind="$2";     shift 2 ;;
      --writer-subtype)  writer_subtype="$2";  shift 2 ;;
      --writer-skill)    writer_skill="$2";    shift 2 ;;
      --project)         project="$2"; project_explicit=1; shift 2 ;;
      --proposed-by)     PROPOSED_BY="$2";     shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$writer_name" ]; then
    printf 'writer.mode_propose: --writer-name <name> required\n' >&2
    return 2
  fi
  if [ -z "$writer_kind" ]; then
    printf 'writer.mode_propose: --writer-kind <connector|agentic-flow|auto-research|scheduled-skill|custom> required\n' >&2
    return 2
  fi
  case "$writer_kind" in
    connector|agentic-flow|auto-research|scheduled-skill|custom)
      ;;
    *)
      printf 'writer.mode_propose: invalid --writer-kind: %s\n' "$writer_kind" >&2
      return 2
      ;;
  esac

  local proposed_by
  proposed_by="${PROPOSED_BY:-user-direct}"

  # Resolve the owning work-project spoke key.
  #   --project <key> explicit -> validate against the registry; a bad override
  #     BLOCKS (lists valid keys, no proposal, never stamp a guessed spoke).
  #   no --project -> auto-resolve from cwd (longest-anchor-wins). A home /
  #     unanchored cwd resolves to the "home" catch-all, which is NOT a project
  #     scope -> dropped to empty so the null-strip omits the project: key.
  local resolved_spoke
  resolved_spoke=""
  if [ "$project_explicit" = "1" ]; then
    if ! resolved_spoke=$(spoke_validate_override "$project" 2>&1); then
      printf '%s\n' "$resolved_spoke" >&2
      return 2
    fi
  else
    resolved_spoke=$(spoke_resolve_from_cwd "$PWD" 2>/dev/null) || resolved_spoke=""
  fi
  if [ "$resolved_spoke" = "home" ]; then
    resolved_spoke=""
  fi

  # Derive slug from writer_name.
  local slug
  slug=$(printf '%s' "$writer_name" | tr 'A-Z' 'a-z' | sed 's/ /-/g; s/[^a-z0-9-]//g')

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local vault_root
  vault_root="${VAULT_ROOT:-$HOME/Documents/Obsidian Vault}"

  # Build a writer-reference frontmatter draft per + Session 5 contract.
  # Conditional fields per writer_kind — operator validates per-field.
  # When a project spoke is resolved, the SUGGESTED default destination is the
  # Form-A vault-view path under $VAULT_ROOT/Work/<spoke>/ — single-keyed for
  # supersession. Otherwise fall back to the operator-templated default.
  local default_dest_path
  if [ -n "$resolved_spoke" ]; then
    default_dest_path="$vault_root/Work/$resolved_spoke/{{date}} - {{title}}.md"
  else
    default_dest_path="{{destination_dir}}/{{date}} - {{title}}.md"
  fi

  local frontmatter_json
  frontmatter_json=$(jq -nc \
    --arg writer_name "$writer_name" \
    --arg writer_kind "$writer_kind" \
    --arg writer_subtype "$writer_subtype" \
    --arg writer_skill "$writer_skill" \
    --arg project "$resolved_spoke" \
    --arg default_dest_path "$default_dest_path" \
    --arg ts "$ts" \
    '
      {
        type: "vault-writer",
        writer_name: $writer_name,
        writer_kind: $writer_kind,
        writer_skill: ($writer_skill | if . == "" then null else . end),
        writer_subtype: ($writer_subtype | if . == "" then null else . end),
        project: ($project | if . == "" then null else . end),
        destinations: [
          {
            path: $default_dest_path,
            output_type: "markdown",
            posture: "direct"
          }
        ],
        status: "active",
        created: ($ts | sub("T.*"; "")),
        updated: ($ts | sub("T.*"; "")),
        tags: ["#scope/writer", "#status/active"]
      }
      | with_entries(select(.value != null))
    ')

  # Add conditional-required fields per writer_kind per + vault-writer.md.json:
  #   connector: writer_subtype + source + authentication
  #   agentic-flow: source
  #   auto-research: source + schedule
  #   scheduled-skill: schedule
  case "$writer_kind" in
    connector)
      frontmatter_json=$(printf '%s' "$frontmatter_json" | jq -c '
        . + {
          source: "<source-identifier>",
          authentication: {method: "<method>", credential_ref: "<ref>"}
        }
      ')
      ;;
    agentic-flow)
      frontmatter_json=$(printf '%s' "$frontmatter_json" | jq -c '. + {source: "<source-skill>"}')
      ;;
    auto-research)
      frontmatter_json=$(printf '%s' "$frontmatter_json" | jq -c '. + {source: "<source>", schedule: "manual"}')
      ;;
    scheduled-skill)
      frontmatter_json=$(printf '%s' "$frontmatter_json" | jq -c '. + {schedule: "manual"}')
      ;;
  esac

  # (T-13): body templates DROPPED. /govern register --kind writer
  # composes frontmatter + body INLINE from contract-field knowledge (the
  # vestigial default + proposal field + the dead literal print line are removed;
  # the _generic-writer file no longer exists).
  jq -nc \
    --arg writer_name "$writer_name" \
    --arg slug "$slug" \
    --arg proposed_by "$proposed_by" \
    --arg vault_root "$vault_root" \
    --argjson frontmatter "$frontmatter_json" \
    '
      {
        kind: "writer",
        target: $writer_name,
        proposed_by: $proposed_by,
        pillars: [
          {
            pillar: "vault_writers",
            payload: {},
            field_descriptions: {},
            notes: "Empty {} payload — writer registration uses the writer-reference file as canonical declaration. The library invocation is purely for atomic action-log row appending under the same lockf serialization."
          }
        ],
        writer_reference: {
          destination: ($vault_root + "/Vault Writers/" + $slug + ".md"),
          frontmatter: $frontmatter
        },
        notes: [
          "Writer registration is structurally distinct — canonical declaration is the Vault Writers/<slug>.md writer-reference file, NOT an overlay-master entry.",
          "Conditional-required fields per writer_kind have placeholder values (e.g., \"<source-identifier>\"). Operator REPLACES these with real values before commit.",
          "destinations[] defaults to a single Mustache-templated entry; the operator MUST set {{destination_dir}} to a blessed vault folder per-flow (no foundation scratch folder ships).",
          "pre-write-guard.sh branch #3 validates the resulting frontmatter against governance/file-type-contracts/vault-writer.md.json on write; schema violation → DENY at hook time."
        ]
      }
    '
}

mode_commit() {
  local proposal="$1"
  shift || true

  if [ ! -r "$proposal" ]; then
    printf 'writer.mode_commit: proposal file not readable: %s\n' "$proposal" >&2
    return 2
  fi

  local target proposed_by destination frontmatter
  target=$(jq -r '.target' "$proposal")
  proposed_by=$(jq -r '.proposed_by // "user-direct"' "$proposal")
  destination=$(jq -r '.writer_reference.destination' "$proposal")
  frontmatter=$(jq '.writer_reference.frontmatter' "$proposal")

  if [ -z "$target" ] || [ "$target" = "null" ]; then
    printf 'writer.mode_commit: proposal missing .target\n' >&2
    return 2
  fi
  if [ -z "$destination" ] || [ "$destination" = "null" ]; then
    printf 'writer.mode_commit: proposal missing .writer_reference.destination\n' >&2
    return 2
  fi
  if [ "$frontmatter" = "null" ]; then
    printf 'writer.mode_commit: proposal missing .writer_reference.frontmatter\n' >&2
    return 2
  fi

  # Compose writer-reference .md file content: YAML frontmatter + body.
  # Frontmatter rendering: jq-to-YAML is verbose; render via python3 to
  # preserve key ordering and quoting.
  local tmpdir
  tmpdir=$(mktemp -d -t govern-register-writer.XXXXXX) || {
    printf 'writer.mode_commit: tempdir creation failed\n' >&2
    return 3
  }
  trap 'rm -rf "$tmpdir"' RETURN

  local writer_md="$tmpdir/writer-reference.md"
  local writer_yaml="$tmpdir/frontmatter.yaml"

  # Render frontmatter as YAML via python3 (yaml stdlib).
  if ! printf '%s' "$frontmatter" | python3 -c '
import sys, json, yaml
data = json.loads(sys.stdin.read())
sys.stdout.write(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
' > "$writer_yaml" 2>/dev/null; then
    printf 'writer.mode_commit: frontmatter YAML render failed (python3 + pyyaml required)\n' >&2
    return 3
  fi

  {
    printf -- '---\n'
    cat "$writer_yaml"
    printf -- '---\n\n'
    printf '# %s\n\n' "$target"
    printf 'Writer-reference file registered via /govern register --kind writer.\n'
  } > "$writer_md" || {
    printf 'writer.mode_commit: writer-reference .md composition failed\n' >&2
    return 3
  }

  # Ensure destination directory exists.
  local dest_dir
  dest_dir=$(dirname "$destination")
  if [ ! -d "$dest_dir" ]; then
    if ! mkdir -p "$dest_dir" 2>/dev/null; then
      printf 'writer.mode_commit: destination dir creation failed: %s\n' "$dest_dir" >&2
      return 6
    fi
  fi

  # Atomic temp+mv into the destination. pre-write-guard.sh branch #3
  # validates the resulting frontmatter against vault-writer.md.json on
  # write — schema violation surfaces as DENY at hook time. (When invoked
  # in foundation-repo authoring context outside a vault, hook doesn't
  # fire and we just write the file.)
  local dest_tmp="$destination.tmp.$$"
  if ! cp "$writer_md" "$dest_tmp"; then
    printf 'writer.mode_commit: writer-reference tempfile write failed\n' >&2
    return 6
  fi
  if ! mv -f "$dest_tmp" "$destination"; then
    rm -f "$dest_tmp"
    printf 'writer.mode_commit: writer-reference atomic rename failed\n' >&2
    return 6
  fi

  # Now invoke library with empty {} payload purely for atomic action-log row.
  local empty_payload="$tmpdir/empty.json"
  printf '{}\n' > "$empty_payload"

  "$LIB_MUTATE" \
    --pillar vault_writers \
    --payload-file "$empty_payload" \
    --kind writer \
    --target "$target" \
    --proposed-by "$proposed_by"
  local rc=$?

  if [ "$rc" != "0" ]; then
    # Writer-reference file already landed (canonical); library row append
    # failed. Surface for librarian audit; do NOT roll back the .md write.
    printf 'writer.mode_commit: library invocation failed rc=%s — writer-reference file at %s retained; surface as drift finding\n' "$rc" "$destination" >&2
    return "$rc"
  fi

  return 0
}
