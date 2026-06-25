#!/usr/bin/env bash
# modes/project.sh — Class F (b / FIX#8) handler for
# /govern register --kind project. The C1/C5 work-project on-ramp.
# A Work spoke is an external-root PROJECT WORKSPACE (~/work/<spoke>/, surfaced
# in the vault as Work/<spoke>/ via the build-time symlink). Registering a
# project mints the on-disk shape via the project-workspace scaffolder, records
# the spoke in the anchored-spoke registry (the identity SoT), and emits the
# vault-view path_routing overlay rule so write-time governance fires for the
# spoke. It NEVER appends to the vault-root CLAUDE.md tree (FIX#3 / folder.sh
# carve-out) — a project's identity lives in its own hub.md.
# TWO SHAPES:
#   --layout flat (default)  : 6-file flat MVP; one overlay rule Work/<spoke>/**.
#   --layout master          : 4-file master top (NO top-level deliverables/
#     --first-sub <name>       reference) + one sub-project; the master offers
#                              the wildcard rule Work/<spoke>/*/{deliverables,
#                              reference}/** so one rule covers all current+future
#                              subs (survives a 2nd sub via the union leaf).
# IDENTITY BOUND (/, the #1 recursion control): a spoke entry is
# minted ONLY for a directory EXACTLY ONE level under $WORK_HOME. project.sh
# REJECTS any cwd where canonical(dirname(cwd)) != canonical($WORK_HOME) — the
# registry won't stop depth-2 (no parent edge; longest-anchor-wins), so the guard
# lives here. Only the MASTER registers a spoke; sub-projects are ORGANIZATIONAL
# UNITS — no spoke, no anchor, no hub.md, no CLAUDE.md.
# GROW-LATER sub-modes:
#   --under <spoke> --add-sub <name> : scaffold a sub + emit its overlay rule
#     (priors kept via the union leaf) + idempotently append the master hub.md
#     sub-pointer WITH the FIX#3 guard (never the vault-root CLAUDE.md). On a FLAT
#     spoke: WARN + advise manual relocation (— never auto-move).
#   --adopt : sub->top-level promotion. The operator git mv is EMITTED, not
#     executed; then register the depth-1 spoke + scaffold MISSING-ONLY CLAUDE.md
#     + hub.md (clobber-refusal relaxed for adopt; README/deliverables/reference
#     byte-unchanged). Lossless; ZERO content-file mutation.
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

# Idempotently append a sub-project pointer to the MASTER's hub.md (Block 7
# Deliverables area). FIX#3 guard: this NEVER targets the vault-root CLAUDE.md —
# it targets $WORK_HOME/<spoke>/hub.md. Belt-and-suspenders Work-target refusal
# guards a misdirected call. $1 = spoke, $2 = sub name.
_proj_hub_append_subpointer() {
  local spoke="$1" sub="$2" wh hub line tmp
  wh="$(_proj_work_home)"
  hub="$wh/$spoke/hub.md"
  if [ ! -f "$hub" ]; then
    printf 'project: master hub.md not found for sub-pointer append: %s\n' "$hub" >&2
    return 3
  fi
  line="- $sub/ — sub-project (deliverables/ + reference/)."
  # Idempotent: bail if the pointer already present.
  if grep -qF "- $sub/ — sub-project" "$hub" 2>/dev/null; then
    return 0
  fi
  tmp="$hub.tmp.$$"
  # Insert the pointer inside Block 7 (Deliverables); else append at EOF.
  awk -v line="$line" '
    BEGIN { in_b7 = 0; inserted = 0 }
    /^## 7\. Deliverables/ { in_b7 = 1; print; next }
    /^## / && in_b7 == 1 && inserted == 0 {
      print line
      inserted = 1
      in_b7 = 0
      print
      next
    }
    { print }
    END {
      if (in_b7 == 1 && inserted == 0) { print line }
      else if (inserted == 0) { print line }
    }
  ' "$hub" > "$tmp" || { rm -f "$tmp"; return 6; }
  if ! mv -f "$tmp" "$hub"; then
    rm -f "$tmp"
    return 6
  fi
  return 0
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

# mode_propose — emit the project-registration proposal JSON to stdout.
# Project-specific blocks (registry_anchor + scaffold) folder.sh has neither.
# The depth guard runs here too so an out-of-bound cwd never even proposes.
mode_propose() {
  local layout first_sub under add_sub adopt cwd
  layout="flat"; first_sub=""; under=""; add_sub=""; adopt="0"; cwd="${PWD}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --layout)    layout="$2";    shift 2 ;;
      --first-sub) first_sub="$2"; shift 2 ;;
      --under)     under="$2";     shift 2 ;;
      --add-sub)   add_sub="$2";   shift 2 ;;
      --adopt)     adopt="1";      shift ;;
      --cwd)       cwd="$2";       shift 2 ;;
      --proposed-by) PROPOSED_BY="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local wh; wh="$(_proj_work_home)"
  local wh_canon; wh_canon="$(_proj_canon "$wh")"

  # --under sub-mode (grow-later): no depth guard on cwd; spoke is named.
  if [ -n "$under" ] || [ -n "$add_sub" ]; then
    if [ -z "$under" ] || [ -z "$add_sub" ]; then
      printf 'project.mode_propose: --under <spoke> AND --add-sub <name> both required for the add-sub sub-mode\n' >&2
      return 2
    fi
    jq -nc \
      --arg spoke "$under" --arg sub "$add_sub" \
      '{kind:"project", op:"add-sub", spoke:$spoke, sub:$sub,
        notes:["Scaffolds Work/<spoke>/<sub>/{README,deliverables/,reference/} — NO CLAUDE.md, NO hub.md (organizational unit,/).",
               "Emits the per-sub overlay rule via the union leaf (priors kept).",
               "Appends the sub-pointer to the MASTER hub.md WITH the FIX#3 guard (never the vault-root CLAUDE.md).",
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
               "Registers a depth-1 spoke + scaffolds MISSING-ONLY CLAUDE.md + hub.md (existing README/deliverables/reference byte-unchanged).",
               "Advises retracting the old Work/master/sub/** rule + master hub pointer. Lossless — ZERO content-file mutation."]}'
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
          then "MASTER: 4-file top (CLAUDE.md+hub.md+README+updates.md, NO top-level deliverables/reference) + sub-project " + $first_sub + " (README+deliverables+reference, NO CLAUDE.md, NO hub.md). wildcard rule covers all current+future subs."
          else "FLAT: 6-file MVP (CLAUDE.md+hub.md+README+updates.md+deliverables/+reference/); one rule Work/" + $spoke + "/**." end),
        "Only the MASTER registers a spoke; sub-projects are organizational units () — no spoke, no anchor, no hub.md, no CLAUDE.md ()."
      ]
    }
    | with_entries(select(.value != null))
    '
}

# mode_commit — apply a validated project proposal.
#   create : registry-patch (master only) + scaffold + overlay rule emit.
#   add-sub: scaffold sub + overlay rule + master hub.md sub-pointer.
#   adopt  : registry-patch + missing-only CLAUDE.md/hub.md scaffold + overlay.
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
      printf 'project: registered spoke %s (layout=%s) — registry + scaffold + overlay rule committed.\n' "$spoke" "$layout" >&2
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
      _proj_emit_overlay_rule "Work/$spoke/$sub" || return $?
      # 3. Master hub.md sub-pointer (FIX#3-guarded — never the vault-root CLAUDE.md).
      _proj_hub_append_subpointer "$spoke" "$sub" || {
        printf 'project.mode_commit: master hub.md sub-pointer append failed (spoke=%s sub=%s)\n' "$spoke" "$sub" >&2
        return 3
      }
      printf 'project: added sub-project %s under %s — scaffold + overlay rule + master hub pointer committed.\n' "$sub" "$spoke" >&2
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
      # 2. Scaffold MISSING-ONLY identity files (CLAUDE.md + hub.md). The
      #    scaffolder refuses to clobber the real spoke dir, so mint the two
      #    identity files directly here, ONLY when absent. README/deliverables/
      #    reference are byte-unchanged (never touched).
      _proj_adopt_mint_identity "$spoke" "$cwd" || return $?
      # 3. Overlay rule for the promoted top-level spoke.
      _proj_emit_overlay_rule "Work/$spoke" || return $?
      printf 'project: ADVISORY — retract the old Work/<master>/%s/** overlay rule + the master hub sub-pointer for %s (now a top-level spoke).\n' "$spoke" "$spoke" >&2
      printf 'project: adopted %s as a top-level spoke — registry + missing-only identity + overlay committed (content byte-unchanged).\n' "$spoke" >&2
      return 0
      ;;

    *)
      printf 'project.mode_commit: unknown op: %s\n' "$op" >&2
      return 2
      ;;
  esac
}

# Mint CLAUDE.md + hub.md for an adopted sub (MISSING-ONLY; relax clobber for
# adopt). Renders hub.md from the foundation hub template (same source the
# scaffolder uses). Existing content files are NEVER touched.
_proj_adopt_mint_identity() {
  local spoke="$1" dir="$2" tdir hub_template today
  today="$(date +%F)"
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
    printf 'project: hub template not found for adopt mint: %s\n' "$hub_template" >&2
    return 3
  fi
  if [ ! -f "$dir/hub.md" ]; then
    sed -e "s/<spoke>/$spoke/g" -e "s/<YYYY-MM-DD>/$today/g" "$hub_template" > "$dir/hub.md" \
      || { printf 'project: adopt hub.md render failed: %s\n' "$dir/hub.md" >&2; return 6; }
  fi
  if [ ! -f "$dir/CLAUDE.md" ]; then
    cat > "$dir/CLAUDE.md" <<EOF
# $spoke — spoke context

@hub.md

This is a \`work/\` spoke (project workspace, adopted from a sub-project). \`hub.md\` is the
eager pointer-only cover page imported above; \`README.md\` is the context doc;
\`updates.md\` (if present) is the append-only updates log. Read deliverable and reference
bodies on-demand — they are not imported here.
EOF
  fi
  return 0
}
