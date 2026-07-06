#!/usr/bin/env bash
# modes/project.sh — Class F (b / FIX#8) handler for
# /govern register --kind project. The C1/C5 work-project on-ramp.
# A Work spoke is an external-root PROJECT WORKSPACE (~/work/<spoke>/, surfaced
# in the vault as Work/<spoke>/ via the build-time symlink). Registering a
# project mints the on-disk shape via the project-workspace scaffolder, records
# the spoke in the anchored-spoke registry (the identity SoT), and emits the
# vault-view path_routing overlay rule so write-time governance fires for the
# spoke. It NEVER appends to the vault-root CLAUDE.md tree (FIX#3 / folder.sh
# carve-out) — a project's identity lives in its own work CLAUDE.md (cross-plan
# state lives in the binder hub at ~/.claude-plans/_projects/<spoke>/hub.md).
# TWO SHAPES:
#   --layout flat (default)  : flat MVP — CLAUDE.md + README + updates.md +
#                              deliverables/ + reference/; one overlay rule
#                              Work/<spoke>/**.
#   --layout master          : master top — CLAUDE.md + README + updates.md (NO
#     --first-sub <name>       top-level deliverables/reference) + one sub-project;
#                              the master offers the wildcard rule
#                              Work/<spoke>/*/{deliverables,reference}/** so one rule
#                              covers all current+future subs (survives a 2nd sub via
#                              the union leaf).
# The work CLAUDE.md carries an auto-maintained directory map (work-map:start/end
# sentinels, re-derived by the work directory-map generator) + README/binder
# pointers — no @import, no plan roster (the binder owns that).
# IDENTITY BOUND (/, the #1 recursion control): a spoke entry is
# minted ONLY for a directory EXACTLY ONE level under $WORK_HOME. project.sh
# REJECTS any cwd where canonical(dirname(cwd)) != canonical($WORK_HOME) — the
# registry won't stop depth-2 (no parent edge; longest-anchor-wins), so the guard
# lives here. Only the MASTER registers a spoke; sub-projects are ORGANIZATIONAL
# UNITS — no spoke, no anchor, no CLAUDE.md.
# GROW-LATER sub-modes:
#   --under <spoke> --add-sub <name> : scaffold a sub + emit its overlay rule
#     (priors kept via the union leaf). The sub listing is auto-derived from disk
#     by the work directory-map generator on the next refresh. On a FLAT spoke:
#     WARN + advise manual relocation (— never auto-move).
#   --adopt : sub->top-level promotion. The operator git mv is EMITTED, not
#     executed; then register the depth-1 spoke + scaffold the MISSING-ONLY work
#     CLAUDE.md (clobber-refusal relaxed for adopt; README/deliverables/reference
#     byte-unchanged) + mint the binder hub. Lossless; ZERO content-file mutation.
# Sourced by process.sh. Exposes mode_propose() and mode_commit().
# bash 3.2 compatible. R-23.

# Path resolution (this file: skills/govern/modes/project.sh).
# REPO_ROOT = skills/govern/modes -> ../../..
_PROJECT_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_PROJECT_REPO_ROOT="$(cd "$_PROJECT_SH_DIR/../../.." && pwd)"
_PROJECT_SCAFFOLD="${PROJECT_SCAFFOLD_SH:-$_PROJECT_SH_DIR/../lib/project-workspace/scaffold.sh}"
_PROJECT_SPOKE_RESOLVE="${SPOKE_RESOLVE_LIB:-$_PROJECT_REPO_ROOT/skills/new-plan/lib/spoke-resolve.sh}"
_PROJECT_FOLDER_SH="${PROJECT_FOLDER_SH:-$_PROJECT_SH_DIR/folder.sh}"

# Canonicalize a path WITHOUT requiring realpath (absent on macOS bash 3.2).
# Matches how the rest of the codebase canonicalizes: cd … && pwd -P. Falls
# back to a normalized string for a not-yet-existing dir.
_proj_canon() {
  local p="$1"
  if [ -d "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd -P ) && return 0
  fi
  # Non-existent dir: strip a trailing slash; leave the literal string.
  printf '%s\n' "${p%/}"
}

# Resolve the active registry path (env override -> reuse spoke-resolve.sh).
_proj_registry_path() {
  if [ -n "${SPOKE_REGISTRY_PATH:-}" ]; then
    printf '%s\n' "$SPOKE_REGISTRY_PATH"
    return 0
  fi
  # shellcheck source=/dev/null
  if [ -r "$_PROJECT_SPOKE_RESOLVE" ]; then
    ( . "$_PROJECT_SPOKE_RESOLVE" 2>/dev/null; spoke_registry_path )
    return 0
  fi
  printf '%s\n' "${CLAUDE_HOME:-$HOME/.claude}/governance/anchored-spoke-registry.json"
}

# Resolve the work-home (env override -> $HOME/work default; matches scaffold.sh).
_proj_work_home() {
  if [ -n "${WORK_HOME:-}" ]; then printf '%s\n' "$WORK_HOME"; return 0; fi
  if [ -n "${BRAIN_STEM_WORK_HOME:-}" ]; then printf '%s\n' "$BRAIN_STEM_WORK_HOME"; return 0; fi
  printf '%s\n' "$HOME/work"
}

# True (rc=0) iff <spoke> is already a registry anchor key.
_proj_spoke_registered() {
  local spoke="$1" reg
  reg="$(_proj_registry_path)"
  [ -r "$reg" ] || return 1
  python3 - "$reg" "$spoke" <<'PY'
import json, sys
reg_path, spoke = sys.argv[1], sys.argv[2]
try:
    reg = json.load(open(reg_path, encoding="utf-8"))
except Exception:
    sys.exit(1)
keys = [sp.get("spoke_key", "") for sp in reg.get("spokes", [])]
sys.exit(0 if spoke in keys else 1)
PY
}

# Atomically add a depth-1 spoke entry to the registry (temp + rename).
# anchored-spoke-registry.json is standalone (NOT overlay-mutable). The anchor is
# the resolved $WORK_HOME/<spoke> path so the longest-anchor resolver matches the
# spoke regardless of whether $WORK_HOME is the production ~/work or a fixture
# mktemp dir (the resolver only tilde-expands ~/$HOME, then normpaths). In
# production $WORK_HOME == ~/work so the anchor is the canonical ~/work/<spoke>.
# BLOCKS (rc!=0) if the spoke already exists (no dup anchor).
_proj_registry_add_spoke() {
  local spoke="$1" reg tmp wh anchor
  reg="$(_proj_registry_path)"
  wh="$(_proj_work_home)"
  anchor="$wh/$spoke"
  if [ ! -r "$reg" ]; then
    printf 'project: registry not readable: %s\n' "$reg" >&2
    return 3
  fi
  tmp="$reg.tmp.$$"
  python3 - "$reg" "$spoke" "$tmp" "$anchor" <<'PY'
import json, sys
reg_path, spoke, tmp, anchor = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    reg = json.load(open(reg_path, encoding="utf-8"))
except Exception as exc:
    print("project: cannot read registry %s (%s)" % (reg_path, exc), file=sys.stderr)
    sys.exit(3)
spokes = reg.setdefault("spokes", [])
for sp in spokes:
    if sp.get("spoke_key", "") == spoke:
        print("project: spoke '%s' already registered — re-registration BLOCKED "
              "(no dup anchor, no re-scaffold)" % spoke, file=sys.stderr)
        sys.exit(4)
spokes.append({
    "spoke_key": spoke,
    "cwd_anchors": [anchor],
    "description": "Work project spoke '%s' (registered via /govern register --kind project)." % spoke,
})
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(reg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
sys.exit(0)
PY
  local rc=$?
  if [ "$rc" != "0" ]; then
    rm -f "$tmp" 2>/dev/null || true
    return "$rc"
  fi
  if ! mv -f "$tmp" "$reg"; then
    rm -f "$tmp" 2>/dev/null || true
    printf 'project: atomic registry rename failed: %s\n' "$reg" >&2
    return 6
  fi
  return 0
}

# Emit a SIMPLE `<base>/**` path_routing overlay rule for a Work target via the
# single mutation library, REUSING folder.sh's mode_propose to compose the
# {rules:[<rule>]} object shape (FIX#4). folder.sh appends `/**` to the target, so
# the caller passes the BASE (e.g. Work/acme, Work/acme/workstream-2) WITHOUT the
# trailing /**. Routes through overlay-master-mutate.sh --kind folder (a routing-
# rule mutation is folder-class; the project kind is not in the action-log enum).
# Survives a SECOND rule via the union leaf. $1 = vault-view base.
_proj_emit_overlay_rule() {
  local base="$1" payload
  if [ ! -r "$_PROJECT_FOLDER_SH" ]; then
    printf 'project: folder.sh not readable (overlay emit reuse): %s\n' "$_PROJECT_FOLDER_SH" >&2
    return 3
  fi
  payload="$(
    ( . "$_PROJECT_FOLDER_SH"; mode_propose --target "$base" --proposed-by user-direct ) \
      | jq -c '.pillars[] | select(.pillar == "frontmatter") | .payload'
  )"
  if [ -z "$payload" ] || [ "$payload" = "null" ]; then
    printf 'project: overlay payload composition failed for %s\n' "$base" >&2
    return 3
  fi
  _proj_commit_overlay_payload "$payload" "$base/**"
}

# Emit a LITERAL path_routing rule (the wildcard Work/<spoke>/*/{deliverables,
# reference}/** is NOT a simple <base>/** shape, so it cannot ride folder.sh's
# auto-append). Composes the {rules:[{pattern,type,auto_create}]} object
# shape DIRECTLY (byte-structurally identical to folder.sh's emit) so it survives
# the union-leaf merge. $1 = literal pattern, $2 = type slug.
_proj_emit_overlay_rule_literal() {
  local pattern="$1" slug="$2" payload
  payload="$(jq -nc --arg pattern "$pattern" --arg slug "$slug" \
    '{path_routing: {rules: [ {pattern: $pattern, type: $slug, auto_create: true} ]}}')"
  _proj_commit_overlay_payload "$payload" "$pattern"
}

# Route a composed frontmatter pillar payload through the single mutation library.
# $1 = compact JSON payload, $2 = target string for the action-log row.
_proj_commit_overlay_payload() {
  local payload="$1" target="$2" tmpdir rc
  if [ ! -x "${LIB_MUTATE:-}" ] && [ ! -r "${LIB_MUTATE:-}" ]; then
    printf 'project: LIB_MUTATE unset/unreadable: %s\n' "${LIB_MUTATE:-}" >&2
    return 3
  fi
  tmpdir=$(mktemp -d -t govern-register-project.XXXXXX) || {
    printf 'project: tempdir creation failed\n' >&2
    return 3
  }
  printf '%s\n' "$payload" > "$tmpdir/payload.json"
  # shellcheck disable=SC2086
  "$LIB_MUTATE" \
    --pillar frontmatter --payload-file "$tmpdir/payload.json" \
    --kind folder --target "$target" --proposed-by user-direct
  rc=$?
  rm -rf "$tmpdir"
  return "$rc"
}

# Remove an EMPTY operator-created spoke launch dir so the (clobber-refusing)
# scaffolder can mint it fresh. Non-existent dir -> no-op. Non-empty real dir ->
# BLOCK (never destroy operator content). A symlink -> leave it (scaffolder
# tolerates a symlink). $1 = spoke dir path.
_proj_clear_empty_launch_dir() {
  local d="$1"
  [ -e "$d" ] || return 0
  if [ -L "$d" ]; then
    return 0
  fi
  if [ -d "$d" ]; then
    if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
      rmdir "$d" 2>/dev/null || {
        printf 'project: could not clear empty launch dir: %s\n' "$d" >&2
        return 3
      }
      return 0
    fi
    printf 'project: launch dir is NON-EMPTY: %s — refusing to scaffold over operator content (block-and-log)\n' "$d" >&2
    return 3
  fi
  printf 'project: launch path exists and is not a directory: %s\n' "$d" >&2
  return 3
}

# Best-effort mint of the spoke's deliverables/ + reference/ _index.md via the
# work-scoped index pass, so the AC-required folder indexes EXIST immediately after
# registration (scaffold.sh does NOT mint _index.md). Resolves the capability path
# repo-local-then-live (mirrors the add-sub work-map auto-derive), suppresses findings,
# ignores rc — block-and-log, NEVER fails registration. $1 = spoke key. Adopter-neutral.
_proj_workindex_mint() {
  local spoke="$1" wh cap
  wh="$(_proj_work_home)"
  cap=""
  for _wic in "$_PROJECT_REPO_ROOT/skills/librarian/capabilities/work-index-maintain.sh" \
              "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/work-index-maintain.sh"; do
    if [ -f "$_wic" ]; then cap="$_wic"; break; fi
  done
  if [ -n "$cap" ]; then
    WORK_HOME="$wh" FINDINGS_OUTPUT="/dev/null" \
      bash "$cap" --spoke "$spoke" >/dev/null 2>&1 || true
  fi
  return 0
}

# mode_propose — emit the project-registration proposal JSON to stdout.
# Project-specific blocks (registry_anchor + scaffold) folder.sh has neither.
# The depth guard runs here too so an out-of-bound cwd never even proposes.
mode_propose() {
  local layout first_sub under add_sub add_folder role adopt cwd
  layout="flat"; first_sub=""; under=""; add_sub=""; add_folder=""; role=""; adopt="0"; cwd="${PWD}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --layout)     layout="$2";     shift 2 ;;
      --first-sub)  first_sub="$2";  shift 2 ;;
      --under)      under="$2";      shift 2 ;;
      --add-sub)    add_sub="$2";    shift 2 ;;
      --add-folder) add_folder="$2"; shift 2 ;;
      --role)       role="$2";       shift 2 ;;
      --adopt)      adopt="1";       shift ;;
      --cwd)        cwd="$2";        shift 2 ;;
      --proposed-by) PROPOSED_BY="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local wh; wh="$(_proj_work_home)"
  local wh_canon; wh_canon="$(_proj_canon "$wh")"

  # --add-folder sub-mode (grow-later): mint a PLAIN top-level folder (NOT a
  # sub-project) under Work/<spoke>. No depth guard on cwd; the spoke is named.
  # Must dispatch BEFORE the add-sub branch (which fires on --under alone).
  if [ -n "$add_folder" ]; then
    if [ -z "$under" ]; then
      printf 'project.mode_propose: --under <spoke> required with --add-folder <name>\n' >&2
      return 2
    fi
    case "$add_folder" in
      */*|.*|"") printf 'project.mode_propose: invalid folder name: %s (no slashes, no leading dot)\n' "$add_folder" >&2; return 2 ;;
    esac
    # The overlay routing rule for the folder: default type-slug = the folder-name
    # slug (folder.sh's own basename default, e.g. People -> people); --role, when
    # given, OVERRIDES it as an explicit label. role="" => folder.sh default is used.
    jq -nc \
      --arg spoke "$under" --arg folder "$add_folder" \
      --arg role "$role" \
      '{kind:"project", op:"add-folder", spoke:$spoke, folder:$folder,
        role:($role | if . == "" then null else . end),
        notes:["Mints a PLAIN top-level folder Work/<spoke>/<name> — NO deliverables/reference, NO README, NO CLAUDE.md, NO registry write (an organizational unit, not a sub-project or a spoke).",
               "Emits its overlay routing rule Work/<spoke>/<name>/** by default (mirrors --add-sub); the routing type-slug is the folder-name slug, or the --role label when given.",
               "Re-derives the master work-map so the folder appears under \"Other top-level folders (not sub-projects):\".",
               "Re-running on an existing folder BLOCKS via the mode own [ -e ] && die guard (non-destructive)."]}'
    return 0
  fi

  # --under sub-mode (grow-later): no depth guard on cwd; spoke is named.
  if [ -n "$under" ] || [ -n "$add_sub" ]; then
    if [ -z "$under" ] || [ -z "$add_sub" ]; then
      printf 'project.mode_propose: --under <spoke> AND --add-sub <name> both required for the add-sub sub-mode\n' >&2
      return 2
    fi
    jq -nc \
      --arg spoke "$under" --arg sub "$add_sub" \
      '{kind:"project", op:"add-sub", spoke:$spoke, sub:$sub,
        notes:["Scaffolds Work/<spoke>/<sub>/{README,deliverables/,reference/} — NO CLAUDE.md (organizational unit,/).",
               "Emits the per-sub overlay rule via the union leaf (priors kept).",
               "The sub listing is auto-derived from disk by the work directory-map generator on the next refresh.",
               "On a FLAT spoke: WARN + advise manual relocation of existing top-level deliverables/reference (— never auto-moved)."]}'
    return 0
  fi

  # --adopt sub-mode: the operator has already git mv-ed the sub to a
  # depth-1 cwd. Depth guard applies (the adopted dir must be exactly depth-1).
  if [ "$adopt" = "1" ]; then
    local cwd_parent cwd_parent_canon spoke
    cwd_parent="$(dirname "$cwd")"
    cwd_parent_canon="$(_proj_canon "$cwd_parent")"
    if [ "$cwd_parent_canon" != "$wh_canon" ]; then
      printf 'project.mode_propose: --adopt cwd must be EXACTLY one level under $WORK_HOME (%s); got %s (parent %s != %s) — BLOCKED\n' \
        "$wh" "$cwd" "$cwd_parent_canon" "$wh_canon" >&2
      return 2
    fi
    spoke="$(basename "$cwd")"
    jq -nc --arg spoke "$spoke" --arg cwd "$cwd" \
      '{kind:"project", op:"adopt", spoke:$spoke, cwd:$cwd,
        notes:["sub->top-level promotion. The operator git mv is EMITTED, not executed.",
               "Registers a depth-1 spoke + scaffolds the MISSING-ONLY work CLAUDE.md + mints the binder hub (existing README/deliverables/reference byte-unchanged).",
               "Advises retracting the old Work/master/sub/** rule. Lossless — ZERO content-file mutation."]}'
    return 0
  fi

  # Primary create path (flat | master). DEPTH GUARD.
  case "$layout" in flat|master) ;; *) printf 'project.mode_propose: invalid --layout %s (flat|master)\n' "$layout" >&2; return 2 ;; esac
  local cwd_parent cwd_parent_canon cwd_canon spoke
  cwd_canon="$(_proj_canon "$cwd")"
  cwd_parent="$(dirname "$cwd")"
  cwd_parent_canon="$(_proj_canon "$cwd_parent")"
  if [ "$cwd_parent_canon" != "$wh_canon" ]; then
    printf 'project.mode_propose: cwd must be EXACTLY one level under $WORK_HOME (%s) to register a project spoke; got %s — BLOCKED (depth guard; sub-projects are organizational units, not spokes)\n' \
      "$wh" "$cwd" >&2
    return 2
  fi
  spoke="$(basename "$cwd")"
  if [ "$layout" = "master" ] && [ -z "$first_sub" ]; then
    printf 'project.mode_propose: --layout master requires --first-sub <name> (the master scaffolds its first sub-project so the normal path never lingers in MASTER-PENDING)\n' >&2
    return 2
  fi

  jq -nc \
    --arg spoke "$spoke" --arg layout "$layout" --arg first_sub "$first_sub" --arg cwd "$cwd" \
    '
    {
      kind: "project",
      op: "create",
      spoke: $spoke,
      layout: $layout,
      first_sub: ($first_sub | if . == "" then null else . end),
      cwd: $cwd,
      registry_anchor: {
        spoke_key: $spoke,
        cwd_anchor: ("~/work/" + $spoke)
      },
      scaffold: {
        layout: $layout,
        subdir: ($first_sub | if . == "" then null else . end)
      },
      overlay_emit: (
        if $layout == "master" then
          { kind: "literal", pattern: ("Work/" + $spoke + "/*/{deliverables,reference}/**"), slug: "work-project" }
        else
          { kind: "base", base: ("Work/" + $spoke) }
        end
      ),
      notes: [
        "Depth-1 only — a spoke entry is minted ONLY for a directory exactly one level under $WORK_HOME (identity never recurses).",
        (if $layout == "master"
          then "MASTER: master top (CLAUDE.md+README+updates.md, NO top-level deliverables/reference) + sub-project " + $first_sub + " (README+deliverables+reference, NO CLAUDE.md). wildcard rule covers all current+future subs."
          else "FLAT: flat MVP (CLAUDE.md+README+updates.md+deliverables/+reference/); one rule Work/" + $spoke + "/**." end),
        "Only the MASTER registers a spoke; sub-projects are organizational units () — no spoke, no anchor, no CLAUDE.md ()."
      ]
    }
    | with_entries(select(.value != null))
    '
}

# mode_commit — apply a validated project proposal.
#   create : registry-patch (master only) + scaffold + overlay rule emit.
#   add-sub: scaffold sub + overlay rule (sub listing auto-derived from disk).
#   adopt  : registry-patch + missing-only work CLAUDE.md scaffold + binder hub + overlay.
mode_commit() {
  local proposal="$1"
  shift || true
  if [ ! -r "$proposal" ]; then
    printf 'project.mode_commit: proposal file not readable: %s\n' "$proposal" >&2
    return 2
  fi

  local op spoke wh
  op=$(jq -r '.op // "create"' "$proposal")
  wh="$(_proj_work_home)"

  case "$op" in
    create)
      local layout first_sub
      spoke=$(jq -r '.spoke' "$proposal")
      layout=$(jq -r '.layout // "flat"' "$proposal")
      first_sub=$(jq -r '.first_sub // ""' "$proposal")
      if [ -z "$spoke" ] || [ "$spoke" = "null" ]; then
        printf 'project.mode_commit: proposal missing .spoke\n' >&2
        return 2
      fi
      # BLOCK re-registration BEFORE any scaffold or anchor write.
      if _proj_spoke_registered "$spoke"; then
        printf 'project.mode_commit: spoke '\''%s'\'' already registered — BLOCKED (no dup anchor, no re-scaffold)\n' "$spoke" >&2
        return 4
      fi
      # 1. Register the spoke (master == the project; atomic temp+rename).
      _proj_registry_add_spoke "$spoke" || return $?
      # 2. Scaffold the on-disk shape.
      if [ ! -r "$_PROJECT_SCAFFOLD" ]; then
        printf 'project.mode_commit: scaffolder not readable: %s\n' "$_PROJECT_SCAFFOLD" >&2
        return 3
      fi
      # The operator runs `/govern register --kind project` FROM the spoke launch
      # dir ($WORK_HOME/<spoke>), so that dir already exists (empty). scaffold.sh
      # refuses to clobber any existing real dir — so remove the EMPTY operator-
      # created launch dir first, letting the scaffolder mint fresh. Refuse if the
      # dir is non-empty (never destroy operator content).
      _proj_clear_empty_launch_dir "$wh/$spoke" || return $?
      bash "$_PROJECT_SCAFFOLD" --spoke "$spoke" --work-home "$wh" --layout "$layout" \
        ${PROJECT_TEMPLATES_DIR:+--templates-dir "$PROJECT_TEMPLATES_DIR"} || {
        printf 'project.mode_commit: scaffold (layout=%s) failed for spoke %s\n' "$layout" "$spoke" >&2
        return 3
      }
      if [ "$layout" = "master" ] && [ -n "$first_sub" ]; then
        bash "$_PROJECT_SCAFFOLD" --spoke "$spoke" --work-home "$wh" --subdir "$first_sub" \
          ${PROJECT_TEMPLATES_DIR:+--templates-dir "$PROJECT_TEMPLATES_DIR"} || {
          printf 'project.mode_commit: sub-project scaffold (%s) failed for spoke %s\n' "$first_sub" "$spoke" >&2
          return 3
        }
      fi
      # 2a. Mint the work-side folder indexes so deliverables/_index.md +
      #     reference/_index.md EXIST immediately after registration (the scaffolder
      #     does not mint _index.md). Best-effort: block-and-log, never fails register.
      _proj_workindex_mint "$spoke"
      # 2b. Establish the binder home + mint the binder-side hub.md (template render,
      #     NOT a generator — preserves C-HUB/R-BIND "no capability generates hub.md").
      _proj_mint_binder_hub "$spoke" || return $?
      # 3. Emit the overlay rule ({rules:[...]} shape via the union leaf).
      #    FLAT  -> simple Work/<spoke>/** (folder.sh auto-append).
      #    MASTER-> literal wildcard Work/<spoke>/*/{deliverables,reference}/**.
      local emit_kind
      emit_kind=$(jq -r '.overlay_emit.kind // "base"' "$proposal")
      if [ "$emit_kind" = "literal" ]; then
        local pat slug
        pat=$(jq -r '.overlay_emit.pattern' "$proposal")
        slug=$(jq -r '.overlay_emit.slug // "work-project"' "$proposal")
        _proj_emit_overlay_rule_literal "$pat" "$slug" || {
          printf 'project.mode_commit: overlay wildcard rule emit failed for %s\n' "$pat" >&2
          return 3
        }
      else
        local base
        base=$(jq -r '.overlay_emit.base' "$proposal")
        _proj_emit_overlay_rule "$base" || {
          printf 'project.mode_commit: overlay rule emit failed for %s\n' "$base" >&2
          return 3
        }
      fi
      printf 'project: registered spoke %s (layout=%s) — registry + scaffold + binder hub + overlay rule committed.\n' "$spoke" "$layout" >&2
      return 0
      ;;

    add-sub)
      local sub layout_now
      spoke=$(jq -r '.spoke' "$proposal")
      sub=$(jq -r '.sub' "$proposal")
      if [ -z "$spoke" ] || [ "$spoke" = "null" ] || [ -z "$sub" ] || [ "$sub" = "null" ]; then
        printf 'project.mode_commit: add-sub proposal missing .spoke/.sub\n' >&2
        return 2
      fi
      if [ ! -d "$wh/$spoke" ]; then
        printf 'project.mode_commit: spoke dir not found for add-sub: %s\n' "$wh/$spoke" >&2
        return 3
      fi
      # FLAT-spoke warning: a flat spoke holds top-level deliverables/.
      # Adding a sub starts a flat->master conversion — WARN + advise manual
      # relocation; NEVER auto-move (historical data is sacred).
      if [ -d "$wh/$spoke/deliverables" ]; then
        printf 'project: WARNING — spoke %s is FLAT (has top-level deliverables/). Adding a sub-project starts a flat->master conversion.\n' "$spoke" >&2
        printf 'project: ADVISORY — manually relocate existing Work/%s/deliverables + reference INTO sub-projects. This tool NEVER auto-moves content ().\n' "$spoke" >&2
      fi
      # 1. Scaffold the sub.
      bash "$_PROJECT_SCAFFOLD" --spoke "$spoke" --work-home "$wh" --subdir "$sub" \
        ${PROJECT_TEMPLATES_DIR:+--templates-dir "$PROJECT_TEMPLATES_DIR"} || {
        printf 'project.mode_commit: sub-project scaffold (%s) failed for spoke %s\n' "$sub" "$spoke" >&2
        return 3
      }
      # 2. Per-sub overlay rule (priors kept via the union leaf).
      #    No work-side hub append — sub listings are auto-derived from disk by the
      #    work directory-map generator on the next refresh (no static sub-pointer).
      _proj_emit_overlay_rule "Work/$spoke/$sub" || return $?
      # 3. Auto-derive the master's work-map so the new sub appears in the master
      #    CLAUDE.md's directory map immediately. Best-effort: block-and-log, ignore
      #    rc, suppress findings — a missing/marker-less generator NEVER fails add-sub.
      _proj_workmap_cap=""
      for _wmc in "$_PROJECT_REPO_ROOT/skills/librarian/capabilities/work-map-generate.sh" \
                  "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/work-map-generate.sh"; do
        if [ -f "$_wmc" ]; then _proj_workmap_cap="$_wmc"; break; fi
      done
      if [ -n "$_proj_workmap_cap" ]; then
        WORK_HOME="$wh" FINDINGS_OUTPUT="/dev/null" \
          bash "$_proj_workmap_cap" --spoke "$spoke" >/dev/null 2>&1 || true
      fi
      # 4. Mint the new sub's work-side folder indexes so the sub's
      #    deliverables/_index.md + reference/_index.md exist immediately. Best-effort.
      _proj_workindex_mint "$spoke"
      printf 'project: added sub-project %s under %s — scaffold + overlay rule committed (master work-map auto-derived from disk).\n' "$sub" "$spoke" >&2
      return 0
      ;;

    add-folder)
      local folder role folder_dir
      spoke=$(jq -r '.spoke' "$proposal")
      folder=$(jq -r '.folder' "$proposal")
      role=$(jq -r '.role // ""' "$proposal")
      if [ -z "$spoke" ] || [ "$spoke" = "null" ] || [ -z "$folder" ] || [ "$folder" = "null" ]; then
        printf 'project.mode_commit: add-folder proposal missing .spoke/.folder\n' >&2
        return 2
      fi
      case "$folder" in
        */*|.*|"") printf 'project.mode_commit: invalid folder name: %s (no slashes, no leading dot)\n' "$folder" >&2; return 2 ;;
      esac
      if [ ! -d "$wh/$spoke" ]; then
        printf 'project.mode_commit: spoke dir not found for add-folder: %s\n' "$wh/$spoke" >&2
        return 3
      fi
      folder_dir="$wh/$spoke/$folder"
      # OWN block-on-existing guard — mirrors scaffold.sh's clobber-refusal
      # (`[ -e ] && [ ! -L ] && die`). --add-folder does NOT route through
      # scaffold.sh's --subdir arm (which mints deliverables/reference); it mkdir's a
      # plain folder directly, so it carries its own guard. A symlink is tolerated;
      # a real existing dir BLOCKS (idempotent, non-destructive re-run).
      if [ -e "$folder_dir" ] && [ ! -L "$folder_dir" ]; then
        printf 'project.mode_commit: refusing to clobber existing folder: %s (block-on-existing; re-run is non-destructive)\n' "$folder_dir" >&2
        return 2
      fi
      # 1. mkdir a PLAIN non-sub folder — NO deliverables/reference, NO README, NO
      #    CLAUDE.md, NO registry write (an organizational unit, not a spoke).
      mkdir -p "$folder_dir" || {
        printf 'project.mode_commit: mkdir failed for add-folder: %s\n' "$folder_dir" >&2
        return 3
      }
      # 2. Emit the routing rule (default a=YES). Default type-slug is the
      #    folder-name slug via folder.sh's own basename default; --role overrides it
      #    as an explicit label. The --target stays QUOTED end-to-end through
      #    _proj_emit_overlay_rule[_literal] -> overlay-master-mutate.sh.
      if [ -n "$role" ]; then
        _proj_emit_overlay_rule_literal "Work/$spoke/$folder/**" "$role" || return $?
      else
        _proj_emit_overlay_rule "Work/$spoke/$folder" || return $?
      fi
      # 3. Re-derive the master work-map so the folder appears under "Other top-level
      #    folders". Best-effort: block-and-log, ignore rc (mirrors add-sub).
      _proj_workmap_cap=""
      for _wmc in "$_PROJECT_REPO_ROOT/skills/librarian/capabilities/work-map-generate.sh" \
                  "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/work-map-generate.sh"; do
        if [ -f "$_wmc" ]; then _proj_workmap_cap="$_wmc"; break; fi
      done
      if [ -n "$_proj_workmap_cap" ]; then
        WORK_HOME="$wh" FINDINGS_OUTPUT="/dev/null" \
          bash "$_proj_workmap_cap" --spoke "$spoke" >/dev/null 2>&1 || true
      fi
      printf 'project: added folder %s under %s — plain non-sub folder + routing rule committed (NO registry write; master work-map re-derived). Defaults: emit-rule=YES, type-slug=%s, block-on-existing=own-guard.\n' \
        "$folder" "$spoke" "${role:-<folder-name slug>}" >&2
      return 0
      ;;

    adopt)
      spoke=$(jq -r '.spoke' "$proposal")
      local cwd
      cwd=$(jq -r '.cwd // ""' "$proposal")
      if [ -z "$spoke" ] || [ "$spoke" = "null" ]; then
        printf 'project.mode_commit: adopt proposal missing .spoke\n' >&2
        return 2
      fi
      [ -n "$cwd" ] || cwd="$wh/$spoke"
      if [ ! -d "$cwd" ]; then
        printf 'project.mode_commit: adopt target dir not found: %s (operator must git mv the sub to %s first)\n' "$cwd" "$wh/$spoke" >&2
        return 3
      fi
      if _proj_spoke_registered "$spoke"; then
        printf 'project.mode_commit: spoke '\''%s'\'' already registered — BLOCKED (no dup anchor)\n' "$spoke" >&2
        return 4
      fi
      # EMIT the operator git mv guidance (already done by the operator; echoed
      # for the audit trail — the tool never executes the move).
      printf 'project: ADOPT — operator git mv (EMITTED, not executed): git mv <old-master>/%s %s\n' "$spoke" "$cwd" >&2
      # 1. Register the depth-1 spoke.
      _proj_registry_add_spoke "$spoke" || return $?
      # 2. Scaffold the MISSING-ONLY work CLAUDE.md (the spoke's identity file). The
      #    scaffolder refuses to clobber the real spoke dir, so mint the identity file
      #    directly here, ONLY when absent, via the SHARED renderer (byte-identical to
      #    the register path). README/deliverables/reference are byte-unchanged (never
      #    touched). No work-side hub.md is minted — cross-plan state lives in the binder.
      _proj_adopt_mint_identity "$spoke" "$cwd" || return $?
      # 2a. Mint the work-side folder indexes for the promoted spoke so its
      #     deliverables/_index.md + reference/_index.md exist immediately. Best-effort.
      _proj_workindex_mint "$spoke"
      # 2b. Establish the binder home + mint the binder-side hub.md (the curated cover
      #     page at $plans_root/_projects/<spoke>/hub.md; separate tree, missing-only render).
      _proj_mint_binder_hub "$spoke" || return $?
      # 3. Overlay rule for the promoted top-level spoke.
      _proj_emit_overlay_rule "Work/$spoke" || return $?
      printf 'project: ADVISORY — retract the old Work/<master>/%s/** overlay rule for %s (now a top-level spoke).\n' "$spoke" "$spoke" >&2
      printf 'project: adopted %s as a top-level spoke — registry + missing-only identity + binder hub + overlay committed (content byte-unchanged).\n' "$spoke" >&2
      return 0
      ;;

    *)
      printf 'project.mode_commit: unknown op: %s\n' "$op" >&2
      return 2
      ;;
  esac
}

# Mint the work CLAUDE.md for an adopted sub (MISSING-ONLY; relax clobber for
# adopt). NO work-side hub.md is minted — the adopted spoke's cross-plan state lives
# in the binder hub (_proj_mint_binder_hub, minted separately). The work CLAUDE.md
# shape MUST stay byte-identical to the register path: both render via the SHARED
# flat renderer SOURCED from scaffold.sh (the single source of truth for the frozen
# work-CLAUDE.md interface — directory-map block + README/binder pointers, no @import).
# Existing content files are NEVER touched.
_proj_adopt_mint_identity() {
  local spoke="$1" dir="$2"
  if [ ! -f "$dir/CLAUDE.md" ]; then
    # shellcheck source=/dev/null
    if [ -r "$_PROJECT_SCAFFOLD" ]; then
      . "$_PROJECT_SCAFFOLD"
    fi
    if ! type _pw_emit_flat_claude_md >/dev/null 2>&1; then
      printf 'project: shared work-CLAUDE.md renderer unavailable (scaffold.sh: %s)\n' "$_PROJECT_SCAFFOLD" >&2
      return 3
    fi
    _pw_emit_flat_claude_md "$spoke" > "$dir/CLAUDE.md" \
      || { printf 'project: adopt CLAUDE.md render failed: %s\n' "$dir/CLAUDE.md" >&2; return 6; }
  fi
  return 0
}

# Establish the project binder home + mint the binder-side hub.md for a spoke.
#   $1 = spoke key.
# Creates ~/.claude-plans/_projects/<spoke>/ (idempotent; also mints the _projects/
# parent if absent) then renders hub.md from the foundation hub template MISSING-ONLY
# (never clobbers a curated hub). This is a template render, NOT a generator — it
# preserves the C-HUB/R-BIND invariant "no librarian capability generates hub.md."
# The binder hub ($plans_root/_projects/<spoke>/hub.md) is the ONLY hub.md in play —
# the work spoke carries no hub.md (its CLAUDE.md owns identity + directory map).
_proj_mint_binder_hub() {
  local plans_root binder_home tdir hub_template today tmp
  # Plans root — the established sibling resolution convention.
  plans_root="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
  case "$plans_root" in */) plans_root="${plans_root%/}" ;; esac
  binder_home="$plans_root/_projects/$1"
  mkdir -p "$binder_home" || {
    printf 'project: binder home mkdir failed: %s\n' "$binder_home" >&2
    return 3
  }
  # Resolve a templates dir (explicit env -> $CLAUDE_HOME/templates -> repo).
  if [ -n "${PROJECT_TEMPLATES_DIR:-}" ]; then
    tdir="$PROJECT_TEMPLATES_DIR"
  elif [ -n "${CLAUDE_HOME:-}" ] && [ -d "$CLAUDE_HOME/templates" ]; then
    tdir="$CLAUDE_HOME/templates"
  else
    tdir="$_PROJECT_REPO_ROOT/templates"
  fi
  hub_template="$tdir/hub-template.md"
  if [ ! -f "$hub_template" ]; then
    printf 'project: hub template not found for binder mint: %s\n' "$hub_template" >&2
    return 3
  fi
  # Hub mint — MISSING-ONLY, never clobber a curated hub. Atomic temp+mv render.
  if [ ! -f "$binder_home/hub.md" ]; then
    today="$(date +%F)"
    tmp="$binder_home/.hub.md.tmp.$$"
    sed -e "s/<spoke>/$1/g" -e "s/<YYYY-MM-DD>/$today/g" "$hub_template" > "$tmp" \
      || { rm -f "$tmp"; printf 'project: binder hub.md render failed: %s\n' "$binder_home/hub.md" >&2; return 6; }
    if ! mv -f "$tmp" "$binder_home/hub.md"; then
      rm -f "$tmp"
      printf 'project: binder hub.md commit failed: %s\n' "$binder_home/hub.md" >&2
      return 6
    fi
  fi
  return 0
}
