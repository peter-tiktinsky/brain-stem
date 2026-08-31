#!/usr/bin/env bash
# skills/onboarder/scripts/build-brain-vault.sh — Tier-2 inline brain-vault build.
#
# Builds a FRESH "brain" vault inline from's slim user-manifest.json: seeds the
# vault-init/ tree, wires the runtime Plans/Skills symlinks, authors <vault>/CLAUDE.md
# from the slim vault template, and emits an Obsidian-open handoff + install closing
# message. The clean Tier-2 successor to skills/adopt/adopt.sh's fresh-vault path
# (which read the dropped vault.is_fresh, defaulted top_folder to Engagements, and
# scaffolded the wrong tree — Inbox/ + .coordination/ + root System Backlog.md). No
# /adopt call anywhere in the Tier-2 GA path.
#
# OUTPUT CONTRACT (R-43):
#   Files written (under the resolved vault root):
#     - <vault>/  + the vault-init/ tree (Vault Writers/ + _index.md)
#     - <vault>/Plans    -> symlink to plans_root (// ~/.claude-plans)
#     - <vault>/Skills   -> symlink to $CLAUDE_HOME/skills/
#     - <vault>/Wiki     -> symlink to plans_root/_library/   (link_vault_root)
#     - <vault>/Projects -> symlink to plans_root/_projects/  (link_vault_root)
#     - <vault>/Work     -> symlink to $WORK_HOME (// ~/work)  (link_vault_root;
#       — the 4th context surface, deliverable home. $WORK_HOME is an
#       external unscaffolded root, mkdir -p'd here first so the link resolves [])
#     - <vault>/.obsidian/app.json  userIgnoreFilters += Plans/_library,
#       Plans/_projects, /Work\/<spoke>\/reference\// (visibility
#       suppression only, no-clobber)
#     - plans_root/_library/ + plans_root/_projects/  surface homes (scaffolded)
#     - $WORK_HOME/  external deliverable home (mkdir -p'd)
#     - $CLAUDE_WORKSHOP_DIR/ (= $CLAUDE_STATE_ROOT/workshop, via paths.sh;
#       the ephemeral workshop home, never a hardcoded literal)
#     - <vault>/CLAUDE.md  (authored from templates/vault-claude-md-template.md;
#       atomic tmp+rename)
#   NO <vault>/System Backlog.md (deferred to ~/.claude-plans/_backlog.md).
#   Pre-write validation: manifest + template + vault-init readable; rendered
#     CLAUDE.md carries zero {{[A-Z_]+}} residue.
#   Failure mode: BLOCK AND LOG. Refuses (exit 2) when NO vault root is configured
#     — the arg -> .paths.vault_root -> .vault.root chain exhausting is a refusal,
#     never an invented location; the diagnostic names the manifest key to set.
#     Refuses to scaffold into a non-empty FOREIGN
#     directory (not a brain vault we built) without --force. REFUSES every
#     vault-root symlink (Plans/Skills/Wiki/Projects) whose target name already
#     exists as a PRE-EXISTING REAL DIRECTORY (not a symlink) — diagnostic names
#     the path + remedy; never silently nests a symlink inside a real dir.
#     CLAUDE.md is not clobbered without --force (preserve user edits). Idempotent
#     re-run on a brain vault we built preserves existing files (cp -n, ln -sfn
#     over an existing correct symlink, CLAUDE.md no-clobber, app.json no-clobber).
#
# {{VAULT_TOP_LEVEL_FOLDER}} resolution: clusters were CUT from the interview
#   in favor of a runtime propose-and-validate folder flow. No user cluster
#   is created at build. Substituted to <USER_CLUSTER_1> (a hand-edit stub,
#   consistent with the template's <USER_CLUSTER_2>/<USER_CLUSTER_N> lines).
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   build-brain-vault.sh [--user-manifest PATH] [--template PATH] [--vault-init DIR]
#                        [--vault-root PATH] [--plans-home PATH] [--skills-dir PATH]
#                        [--force] [--dry-run]
#
# Exit codes:
#   0   success | dry-run
#   2   bad invocation / missing dependency / non-empty foreign vault without --force
#   1   build / render / residue / IO failure (block-and-log)
#
# Author: Claude Opus 4.7 (1M context) —
set -u

diag() { printf 'build-brain-vault FAIL: %s\n' "$1" >&2; }
info() { printf 'build-brain-vault: %s\n' "$1" >&2; }

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# Self-contained skill: the shared vault template + the C1-owned vault-init/
# seed STAY in their install-co-owned homes; resolve via $CLAUDE_HOME (no REPO_ROOT walk).
USER_MANIFEST="$CLAUDE_HOME/user-manifest.json"
TEMPLATE="$CLAUDE_HOME/templates/vault-claude-md-template.md"
VAULT_INIT="$CLAUDE_HOME/vault-init"
VAULT_ROOT_ARG=""
PLANS_HOME_ARG=""
SKILLS_DIR_ARG=""
FORCE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user-manifest) USER_MANIFEST="$2"; shift 2 ;;
    --template)      TEMPLATE="$2"; shift 2 ;;
    --vault-init)    VAULT_INIT="$2"; shift 2 ;;
    --vault-root)    VAULT_ROOT_ARG="$2"; shift 2 ;;
    --plans-home)    PLANS_HOME_ARG="$2"; shift 2 ;;
    --skills-dir)    SKILLS_DIR_ARG="$2"; shift 2 ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       sed -n '2,52p' "$0"; exit 0 ;;
    *)               diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { diag "jq required on PATH"; exit 2; }
[ -f "$TEMPLATE" ]      || { diag "vault template not found: $TEMPLATE"; exit 2; }
[ -d "$VAULT_INIT" ]    || { diag "vault-init dir not found: $VAULT_INIT"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }
jq -e . "$USER_MANIFEST" >/dev/null 2>&1 || { diag "user-manifest is not valid JSON: $USER_MANIFEST"; exit 2; }

mf_get() { jq -r "$1 // \"\"" "$USER_MANIFEST" 2>/dev/null; }
expand_tilde() { case "$1" in "~/"*) printf '%s' "$HOME/${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }

# --- resolve paths ---
NAME="$(mf_get '.identity.name')"; [ -z "$NAME" ] && NAME="(unknown)"

VAULT_ROOT="$VAULT_ROOT_ARG"
[ -z "$VAULT_ROOT" ] && VAULT_ROOT="$(mf_get '.paths.vault_root')"
[ -z "$VAULT_ROOT" ] && VAULT_ROOT="$(mf_get '.vault.root')"
# The vault root has NO install-convention default (the paths SoT publishes that
# contract and holds the variable empty). So an exhausted chain is a REFUSAL, not a
# fallback: inventing a location here would scaffold a whole vault, and every
# symlink in it, somewhere the adopter never nominated — silently, and only
# discoverable after the fact. Fail loudly and name the key to set.
if [ -z "$VAULT_ROOT" ]; then
  diag "no vault root configured — --vault-root was not given and .paths.vault_root is empty (mirror .vault.root also empty) in: $USER_MANIFEST"
  diag "set .paths.vault_root in that user-manifest, or pass --vault-root PATH. There is no default vault location to fall back to."
  exit 2
fi
VAULT_ROOT="$(expand_tilde "$VAULT_ROOT")"

PLANS_HOME="$PLANS_HOME_ARG"
[ -z "$PLANS_HOME" ] && PLANS_HOME="$(mf_get '.paths.plans_root')"
[ -z "$PLANS_HOME" ] && PLANS_HOME="${PLANS_HOME:-$HOME/.claude-plans}"
PLANS_HOME="$(expand_tilde "$PLANS_HOME")"

SKILLS_DIR="$SKILLS_DIR_ARG"
[ -z "$SKILLS_DIR" ] && SKILLS_DIR="$CLAUDE_HOME/skills"

# Work deliverable home: the 4th context surface. 3-tier resolver
# mirroring paths.sh — env BRAIN_STEM_WORK_HOME > manifest .paths.work_root >
# default $HOME/work. Resolved inline here (self-contained skill) exactly
# as PLANS_HOME is, rather than sourcing paths.sh.
WORK_HOME="${BRAIN_STEM_WORK_HOME:-}"
[ -z "$WORK_HOME" ] && WORK_HOME="$(mf_get '.paths.work_root')"
[ -z "$WORK_HOME" ] && WORK_HOME="$HOME/work"
WORK_HOME="$(expand_tilde "$WORK_HOME")"

CLAUDE_MD="$VAULT_ROOT/CLAUDE.md"
MARKER="$VAULT_ROOT/Vault Writers/_index.md"   # presence => brain vault we built

# --- non-empty foreign-vault guard ---
# Empty / missing      -> fresh build.
# Our brain vault      -> idempotent overlay (marker present).
# Foreign non-empty    -> refuse without --force (retrofit-existing is).
IS_BRAIN_VAULT=0
[ -f "$MARKER" ] && IS_BRAIN_VAULT=1
NON_EMPTY=0
if [ -d "$VAULT_ROOT" ] && [ -n "$(ls -A "$VAULT_ROOT" 2>/dev/null)" ]; then NON_EMPTY=1; fi
if [ "$NON_EMPTY" = "1" ] && [ "$IS_BRAIN_VAULT" = "0" ] && [ "$FORCE" != "1" ]; then
  diag "vault root is a non-empty FOREIGN directory: $VAULT_ROOT"
  diag "refusing to scaffold into it. Pass --force to override, or use the"
  diag "retrofit-existing flow for an existing vault."
  exit 2
fi

# --- dry-run summary ---
if [ "$DRY_RUN" = "1" ]; then
  cat >&2 <<EOF
build-brain-vault: dry-run summary
  vault_root:   $VAULT_ROOT  $([ "$IS_BRAIN_VAULT" = 1 ] && echo "(existing brain vault — idempotent overlay)" || ([ "$NON_EMPTY" = 1 ] && echo "(non-empty foreign — needs --force)" || echo "(fresh)"))
  plans_home:   $PLANS_HOME
  skills_dir:   $SKILLS_DIR
  identity:     $NAME
  would_seed:   vault-init/ tree (Vault Writers/)
  would_scaffold: $PLANS_HOME/_library ; $PLANS_HOME/_projects ; \${CLAUDE_WORKSHOP_DIR:-\$CLAUDE_STATE_ROOT/workshop} ; $WORK_HOME ()
  would_link:   $VAULT_ROOT/Plans -> $PLANS_HOME ; $VAULT_ROOT/Skills -> $SKILLS_DIR
                $VAULT_ROOT/Wiki -> $PLANS_HOME/_library ; $VAULT_ROOT/Projects -> $PLANS_HOME/_projects
                $VAULT_ROOT/Work -> $WORK_HOME ()
                (real-dir guard: refuse-with-diagnostic if any name pre-exists as a real dir)
  would_ignore: .obsidian/app.json userIgnoreFilters += Plans/_library, Plans/_projects, /Work\/<spoke>\/reference\// (visibility suppression; no-clobber)
  would_author: $CLAUDE_MD  ({{VAULT_TOP_LEVEL_FOLDER}} -> <USER_CLUSTER_1>)
EOF
  echo "DRY-RUN: complete — zero filesystem mutations" >&2
  exit 0
fi

# --- 1. seed vault-init/ tree (cp -n: idempotent; never clobber existing) ---
mkdir -p "$VAULT_ROOT" || { diag "mkdir vault root failed: $VAULT_ROOT"; exit 1; }
# bash 3.2 has no cp -Rn that's portable across BSD/GNU for "no-clobber recursive";
# copy file-by-file with -n via find to stay deterministic on macOS + Linux.
( cd "$VAULT_INIT" && find . -type d ) | while IFS= read -r d; do
  mkdir -p "$VAULT_ROOT/$d" || { diag "mkdir $VAULT_ROOT/$d failed"; exit 1; }
done || { diag "vault-init directory seed failed"; exit 1; }
# (T-12): vault-init/ ships the MANDATORY committed static
# Vault Writers/_index.md file. The copy loop seeds every committed file
# except the .gitkeep dir-placeholders, so the Vault Writers/_index.md
# idempotency MARKER (see :131) is produced on the first build — a re-run
# then matches IS_BRAIN_VAULT (marker present) and overlays idempotently
# instead of hitting the foreign-vault guard. (RED-NOW was a .gitkeep-only
# tree → zero content seeded → marker never produced → re-run REFUSED
# without --force.)
( cd "$VAULT_INIT" && find . -type f ! -name '.gitkeep' ) | while IFS= read -r f; do
  dest="$VAULT_ROOT/$f"
  [ -f "$dest" ] && continue                       # idempotent: preserve existing
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  cp "$VAULT_INIT/$f" "$dest" || { diag "cp $f failed"; exit 1; }
done || { diag "vault-init file seed failed"; exit 1; }

# --- 2. runtime symlinks (ln -sfn: idempotent) ---
# REAL-DIR GUARD: a bare `ln -sfn TARGET <vault>/NAME` silently
# NESTS the link INSIDE a pre-existing real directory at <vault>/NAME (ln -sfn
# only force-replaces an EXISTING SYMLINK; against a real dir it creates
# <vault>/NAME/<basename-of-TARGET>). Every vault-root symlink (Plans, Skills,
# Wiki, Projects) routes through link_vault_root, which REFUSES with a diagnostic
# when <vault>/NAME exists as a real directory (not a symlink) and never nests.
# An existing correct symlink (or any symlink) is force-replaced idempotently.
link_vault_root() {
  # $1 = link target, $2 = vault-root link name (e.g. "Plans")
  local target="$1" name="$2" path="$VAULT_ROOT/$2"
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    diag "vault-root '$name' already exists as a REAL DIRECTORY: $path"
    diag "  refusing to create the '$name' symlink — a bare 'ln -sfn' would NEST"
    diag "  the link inside it. Remedy: move/rename '$path' out of the vault root"
    diag "  (it is not a brain-stem surface), then re-run the build so '$name' can"
    diag "  be created as the '$target' symlink."
    return 1
  fi
  ln -sfn "$target" "$path" || { diag "$name symlink failed"; return 1; }
}

mkdir -p "$PLANS_HOME" 2>/dev/null || { diag "mkdir plans_home failed: $PLANS_HOME"; exit 1; }
# Surface homes the Wiki/Projects views point at (
# underscore-system-folders at the plans root). Scaffold idempotently so the
# symlinks resolve immediately on a fresh install.
mkdir -p "$PLANS_HOME/_library" "$PLANS_HOME/_projects" 2>/dev/null \
  || { diag "mkdir _library/_projects failed under $PLANS_HOME"; exit 1; }
# Workshop home: resolve the XDG ephemeral root via paths.sh — never a
# hardcoded literal. CLAUDE_WORKSHOP_DIR is exported by hooks/lib/paths.sh
# ($CLAUDE_STATE_ROOT/workshop); fall back to the same XDG convention if paths.sh
# was not sourced into this environment.
WORKSHOP_DIR="${CLAUDE_WORKSHOP_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/workshop}"
mkdir -p "$WORKSHOP_DIR" 2>/dev/null || { diag "mkdir workshop home failed: $WORKSHOP_DIR"; exit 1; }

link_vault_root "$PLANS_HOME"           "Plans"    || exit 1
link_vault_root "$SKILLS_DIR"           "Skills"   || exit 1
link_vault_root "$PLANS_HOME/_library"  "Wiki"     || exit 1   # real-dir-guarded
link_vault_root "$PLANS_HOME/_projects" "Projects" || exit 1   # real-dir-guarded

# Work deliverable surface: ~/work/ is an EXTERNAL, unscaffolded root.
# Unlike _library/_projects (scaffolded under $PLANS_HOME above), no prior step
# creates it, so mkdir -p FIRST or the Work/ symlink would DANGLE on a fresh
# install [audit]. The link_vault_root real-dir guard still refuses to clobber
# a pre-existing real <vault>/Work.
mkdir -p "$WORK_HOME" 2>/dev/null || { diag "mkdir work home failed: $WORK_HOME"; exit 1; }
link_vault_root "$WORK_HOME"            "Work"     || exit 1   # real-dir-guarded

# --- 2b. Obsidian userIgnoreFilters ---
# Suppress the duplicate Plans/_library + Plans/_projects view-paths from search /
# quick-switcher / graph so only the Wiki/ + Projects/ symlink paths surface, PLUS
# the raw Work/<spoke>/reference/ subpaths (reference/ holds raw notes /
# specimens, the polished deliverables/ payload stays visible). The Work entry is a
# regex (spoke names are dynamic) — Obsidian treats /.../-wrapped filters as regex.
# VISIBILITY suppression only — does NOT govern link resolution.
# The Plans/_projects entry fences the WHOLE duplicate binder view-path (the
# binder stays reachable via Projects/) — it deliberately survives the retirement
# of the former binder research/ symlink farm, whose narrower fence it subsumes.
# No-clobber: merge the entries into any existing app.json, preserving every
# adopter-added filter; idempotent (entries added only when absent, via unique).
OBSIDIAN_DIR="$VAULT_ROOT/.obsidian"
APP_JSON="$OBSIDIAN_DIR/app.json"
mkdir -p "$OBSIDIAN_DIR" 2>/dev/null || { diag "mkdir .obsidian failed: $OBSIDIAN_DIR"; exit 1; }
if [ -f "$APP_JSON" ]; then
  EXISTING_APP="$(cat "$APP_JSON")"
else
  EXISTING_APP='{}'
fi
APP_MERGED="$(printf '%s' "$EXISTING_APP" | jq '
  .userIgnoreFilters = ((.userIgnoreFilters // [])
    + ["Plans/_library", "Plans/_projects", "/Work\\/[^/]+\\/reference\\//"] | unique)
' 2>/dev/null)" || APP_MERGED=""
if [ -z "$APP_MERGED" ]; then
  diag "app.json userIgnoreFilters merge failed (invalid JSON at $APP_JSON?)"
  exit 1
fi
APP_TMP="$APP_JSON.tmp.$$"
printf '%s\n' "$APP_MERGED" > "$APP_TMP" || { rm -f "$APP_TMP"; diag "stage app.json failed"; exit 1; }
mv -f "$APP_TMP" "$APP_JSON" || { rm -f "$APP_TMP"; diag "atomic rename app.json failed"; exit 1; }

# --- 2c. Obsidian property types (T-12; UX typing for the cohort) ---
# Seed .obsidian/types.json so Obsidian renders the governed cohort keys as the right
# property KIND: created/updated as `date`, tags/aliases as the plural list forms.
# brain-stem cannot ENFORCE Obsidian's own property types (C3) — the enforceable layer
# is the T-5 write-time format regex (R-64); this is the UX mirror. No-clobber OBJECT-KEY
# merge (distinct from the app.json ARRAY merge above): `SEED + (.types // {})` places the
# adopter's existing declarations on the winning side, so a pre-existing types.json entry
# is always preserved.
TYPES_JSON="$OBSIDIAN_DIR/types.json"
if [ -f "$TYPES_JSON" ]; then
  EXISTING_TYPES="$(cat "$TYPES_JSON")"
else
  EXISTING_TYPES='{}'
fi
TYPES_MERGED="$(printf '%s' "$EXISTING_TYPES" | jq '
  .types = ({"created":"date","updated":"date","tags":"tags","aliases":"aliases"} + (.types // {}))
' 2>/dev/null)" || TYPES_MERGED=""
if [ -z "$TYPES_MERGED" ]; then
  diag "types.json object-key merge failed (invalid JSON at $TYPES_JSON?)"
  exit 1
fi
TYPES_TMP="$TYPES_JSON.tmp.$$"
printf '%s\n' "$TYPES_MERGED" > "$TYPES_TMP" || { rm -f "$TYPES_TMP"; diag "stage types.json failed"; exit 1; }
mv -f "$TYPES_TMP" "$TYPES_JSON" || { rm -f "$TYPES_TMP"; diag "atomic rename types.json failed"; exit 1; }

# --- 3. author <vault>/CLAUDE.md (round-trip subst map) ---
esc() { printf '%s' "$1" | LC_ALL=C sed -e 's/[\\&|]/\\&/g' | tr -d '\n\r'; }
RENDERED_VAULT_MD="$(sed \
  -e "s|{{IDENTITY_NAME}}|$(esc "$NAME")|g" \
  -e "s|{{VAULT_ROOT}}|$(esc "$VAULT_ROOT")|g" \
  -e "s|{{PLANS_HOME}}|$(esc "$PLANS_HOME")|g" \
  -e "s|{{WORK_HOME}}|$(esc "$WORK_HOME")|g" \
  -e "s|{{CLAUDE_HOME}}|$(esc "$CLAUDE_HOME")|g" \
  -e "s|{{VAULT_TOP_LEVEL_FOLDER}}|<USER_CLUSTER_1>|g" \
  "$TEMPLATE")" || { diag "vault CLAUDE.md render failed"; exit 1; }

RESIDUE="$(printf '%s' "$RENDERED_VAULT_MD" | grep -oE '\{\{[A-Z_]+\}\}' | sort -u)"
if [ -n "$RESIDUE" ]; then
  diag "residual placeholders in vault CLAUDE.md: $(printf '%s' "$RESIDUE" | tr '\n' ' ')"
  exit 1
fi

if [ -f "$CLAUDE_MD" ] && [ "$FORCE" != "1" ]; then
  if printf '%s\n' "$RENDERED_VAULT_MD" | cmp -s - "$CLAUDE_MD"; then
    info "vault CLAUDE.md already up to date — no write"
  else
    info "vault CLAUDE.md exists; preserving user edits (--force to overwrite). New render not applied."
  fi
else
  TMP="${CLAUDE_MD}.tmp.$$"
  printf '%s\n' "$RENDERED_VAULT_MD" > "$TMP" || { rm -f "$TMP"; diag "stage vault CLAUDE.md failed"; exit 1; }
  mv "$TMP" "$CLAUDE_MD" || { rm -f "$TMP"; diag "atomic rename vault CLAUDE.md failed"; exit 1; }
fi

# --- 4. Obsidian-open handoff + install closing message ---
cat <<EOF

============================================================
  Your brain-stem "brain" is ready.
============================================================

  Personal preferences:  $CLAUDE_HOME/CLAUDE.md
  Your brain vault:       $VAULT_ROOT

  Seeded in the vault:
    Vault Writers/       catalog of any system that writes into the vault
    Plans/    -> $PLANS_HOME
    Skills/   -> $SKILLS_DIR
    Wiki/     -> $PLANS_HOME/_library    (cross-project library — durable knowledge)
    Projects/ -> $PLANS_HOME/_projects   (per-spoke project binders)
    Work/     -> $WORK_HOME    (your deliverables home — durable work product)
    CLAUDE.md            the vault's structure map (Claude reads this first)

  Open it in Obsidian:
    Open it in Obsidian (Open folder as vault) → select  $VAULT_ROOT
    Confirm when done.

  What's next:
    • Your own top-level folders (clusters) get created organically — just tell
      Claude where work belongs and it proposes a folder, then maintains the
      structure tree in CLAUDE.md for you.
    • Vault-specific rules go in the "<USER: …>" section of $VAULT_ROOT/CLAUDE.md.

============================================================
EOF

info "brain vault built at $VAULT_ROOT"
exit 0
