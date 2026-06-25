#!/usr/bin/env bash
# modes/folder.sh — Class A handler for /govern register --kind folder.
# Class A trigger (new top-level vault folder). R-37 atomic across
# frontmatter.path_routing + (if applicable)
# mandatory_files. Step 6 of protocol (vault-root CLAUDE.md tree
# self-update; no [F] marker per) is performed AFTER the library
# commit succeeds — EXCEPT for a Work or Work/* target, which is carved
# out: a Work spoke is an external-root project workspace whose identity
# lives in its own hub.md, so its registration never appends to the
# vault-root CLAUDE.md tree.
# Sourced by process.sh. Exposes mode_propose() and mode_commit().
# bash 3.2 compatible.

mode_propose() {
  local target inherit_from
  target=""
  inherit_from=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)         target="$2";         shift 2 ;;
      --inherit-from)   inherit_from="$2";   shift 2 ;;
      --proposed-by)    PROPOSED_BY="$2";    shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$target" ]; then
    printf 'folder.mode_propose: --target <vault-relative-path> required\n' >&2
    return 2
  fi

  # Default proposed_by — caller may override (hook-class-a / user-direct).
  local proposed_by
  proposed_by="${PROPOSED_BY:-user-direct}"

  # Derive a sensible default type-slug from the folder name (lowercase,
  # space → hyphen, trim trailing /). Pure heuristic — operator validates.
  local folder_clean folder_basename slug
  folder_clean=$(printf '%s' "$target" | sed 's:/*$::')
  folder_basename=$(printf '%s' "$folder_clean" | sed 's:.*/::')
  slug=$(printf '%s' "$folder_basename" | tr 'A-Z' 'a-z' | sed 's/ /-/g; s/[^a-z0-9-]//g')

  jq -nc \
    --arg target "$target" \
    --arg slug "$slug" \
    --arg inherit "$inherit_from" \
    --arg proposed_by "$proposed_by" \
    '
      {
        kind: "folder",
        target: $target,
        proposed_by: $proposed_by,
        pillars: [
          {
            pillar: "frontmatter",
            payload: {
              path_routing: {
                rules: [
                  {
                    pattern: ($target + "/**"),
                    type: $slug,
                    auto_create: true,
                    inherit_from: ($inherit | if . == "" then null else . end)
                  }
                  | with_entries(select(.value != null))
                ]
              }
            },
            field_descriptions: {
              path_routing: ("Routing rule for vault paths under " + $target + "/; declares default frontmatter type for files in this subtree")
            }
          },
          {
            pillar: "mandatory_files",
            payload: {
              by_folder: {
                ($target + "/**"): ["_index.md"]
              }
            },
            field_descriptions: {
              by_folder: ("Mandatory files in " + $target + "/ — operator confirms whether _index.md is required or removes this pillar from the proposal")
            }
          }
        ],
        notes: [
          "Class A folder registration mutates two pillars atomically (R-37).",
          "If the folder does not need _index.md, REMOVE the mandatory_files pillar entry from the validated proposal before commit.",
          "Step 6 (vault-root CLAUDE.md tree self-update) fires after commit for a vault-root user cluster, and is SKIPPED for a Work or Work/* target. A Work spoke is an external-root project workspace whose identity lives in its own hub.md, never the vault-root CLAUDE.md tree — so no tree-append is performed for it. Operator confirms the tree-edit at that step only when it fires."
        ]
      }
    '
}

# Compose payload tempfiles from a validated proposal and invoke the library.
# Validated proposal shape: same as propose output, but with rejected fields
# removed from .pillars[].payload and per-entry `_override_reason` fields
# inline on each shadowing payload entry (canonical shape; T-5).
mode_commit() {
  local proposal="$1"
  shift || true

  if [ ! -r "$proposal" ]; then
    printf 'folder.mode_commit: proposal file not readable: %s\n' "$proposal" >&2
    return 2
  fi

  local target proposed_by pillar_count
  target=$(jq -r '.target' "$proposal")
  proposed_by=$(jq -r '.proposed_by // "user-direct"' "$proposal")
  pillar_count=$(jq '.pillars | length' "$proposal")

  if [ -z "$target" ] || [ "$target" = "null" ]; then
    printf 'folder.mode_commit: proposal missing .target\n' >&2
    return 2
  fi
  if [ "$pillar_count" -lt 1 ]; then
    printf 'folder.mode_commit: proposal .pillars[] is empty\n' >&2
    return 2
  fi

  # Compose --pillar/--payload-file pairs.
  local tmpdir
  tmpdir=$(mktemp -d -t govern-register-folder.XXXXXX) || {
    printf 'folder.mode_commit: tempdir creation failed\n' >&2
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
    --kind folder \
    --target "$target" \
    --proposed-by "$proposed_by"
  local rc=$?

  if [ "$rc" != "0" ]; then
    printf 'folder.mode_commit: library invocation failed rc=%s\n' "$rc" >&2
    return "$rc"
  fi

  # Step 6 of — vault-root CLAUDE.md tree self-update.
  # Foundation-repo authoring: vault path is provided via env. Failure here
  # does NOT roll back the overlay (canonical; survives); operator triages
  # via librarian governance-parity-audit `vault-claude-md-tree-drift` finding.
  # Work/* carve-out: a Work-spoke target is an external-root project workspace,
  # NOT a vault-root user cluster — its identity lives in its own hub.md, never
  # the vault-root CLAUDE.md Vault Structure tree. Skip the tree-append entirely
  # for any Work or Work/* target (the append would misdirect a project pointer
  # into the vault-root cover).
  case "$target" in
    Work|Work/*) ;;  # carve-out: no vault-root tree-append for Work spokes
    *)
      _folder_claude_md_tree_append "$target" || {
        local update_rc=$?
        printf 'folder.mode_commit: vault-root CLAUDE.md tree self-update failed rc=%s — overlay commit retained; surface as drift finding\n' "$update_rc" >&2
        # Non-fatal — overlay mutation already committed.
      }
      ;;
  esac

  return 0
}

# Append a user-cluster entry to the vault-root CLAUDE.md Vault Structure
# tree. No [F] marker (reserved for foundation-shipped per T-13 v3.1 template).
# Idempotent: if entry already exists, no-op. Locates the Vault Structure
# H2 section and appends within it.
_folder_claude_md_tree_append() {
  local target="$1"
  local vault_root="${VAULT_ROOT:-$HOME/Documents/Obsidian Vault}"
  local claude_md="$vault_root/CLAUDE.md"

  # Defensive Work/* carve-out (belt-and-suspenders with the mode_commit case
  # guard): a Work-spoke target never lands in the vault-root tree — its
  # identity is its own hub.md. Early-return BEFORE any sidecar/file mutation
  # so even a direct call cannot misdirect a project pointer into the cover.
  case "$target" in
    Work|Work/*) return 0 ;;
  esac

  if [ ! -f "$claude_md" ]; then
    # No vault-root CLAUDE.md yet — defer (install scaffolding handles seed).
    # Emit a sidecar marker so librarian surfaces.
    local sidecar="$vault_root/_claude-md-tree-update-pending.json"
    mkdir -p "$vault_root" 2>/dev/null || return 6
    local row
    row=$(jq -nc --arg target "$target" \
      '{pending_user_cluster: $target, reason: "vault-root CLAUDE.md missing", ts: now | strftime("%Y-%m-%dT%H:%M:%SZ")}')
    printf '%s\n' "$row" >> "$sidecar" 2>/dev/null || return 6
    return 0
  fi

  # Bail if entry already present (idempotent).
  if grep -q "^- $target/" "$claude_md" 2>/dev/null; then
    return 0
  fi

  # Locate `## Vault Structure` section; append entry within it.
  # Strategy: write tempfile reading line-by-line; on encountering the next
  # H2 after Vault Structure, insert the new entry just before it. If no
  # subsequent H2, append at end-of-file.
  local tmpfile
  tmpfile="$claude_md.tmp.$$"

  awk -v target="$target" '
    BEGIN { in_vs = 0; inserted = 0 }
    /^## Vault Structure/ { in_vs = 1; print; next }
    /^## / && in_vs == 1 && inserted == 0 {
      print "- " target "/"
      inserted = 1
      in_vs = 0
      print
      next
    }
    { print }
    END {
      if (in_vs == 1 && inserted == 0) {
        print "- " target "/"
      }
    }
  ' "$claude_md" > "$tmpfile" || return 6

  if ! mv -f "$tmpfile" "$claude_md"; then
    rm -f "$tmpfile"
    return 6
  fi

  return 0
}
