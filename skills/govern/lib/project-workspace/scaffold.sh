#!/bin/bash
# scaffold.sh — project-workspace, Seam-1 folder scaffolding for a work/ spoke.
# The executable half of recipe.md.
# Writes ONLY under $WORK_HOME/<spoke>/ (the adopter's work spoke) and NEVER modifies a
# foundation file. That is the load-bearing "zero foundation edits" property the recipe
# proves.
# OUTPUT CONTRACT:
#   files written : --layout flat (default) → $WORK_HOME/<spoke>/{CLAUDE.md, README.md,
#                   updates.md} + deliverables/ + reference/ (dirs) — the MVP shape
#                   (no starters).
#                   --layout master → $WORK_HOME/<spoke>/{CLAUDE.md, README.md, updates.md}
#                   ONLY — NO top-level deliverables/ or reference/ (each sub-project owns
#                   its own).
#                   --subdir <name> → $WORK_HOME/<spoke>/<name>/{README.md, deliverables/,
#                   reference/} under an existing spoke — NEVER a CLAUDE.md
#                   (sub-projects are ORGANIZATIONAL UNITS, identity stays with the master,
#   schema        : the work CLAUDE.md carries project identity, a README/updates pointer,
#                   a binder pointer, and an auto-maintained directory map bounded by the
#                   work-map:start / work-map:end sentinels (generated:true — re-derived by
#                   `librarian work-map-generate`, never hand-edited); README/updates are
#                   free-form spoke docs the adopter owns.
#   pre-write validation : refuses to clobber a pre-existing real spoke dir; --subdir
#                   requires the spoke dir to already exist + a slash-free <name>.
#   failure mode  : block-and-log — validate all inputs first, diagnostic to stderr, non-zero
#                   exit; never partial-write over an existing spoke.
# Usage: scaffold.sh --spoke <name> [--work-home <path>]
#                    [--layout flat|master] [--subdir <name>]
#                    [--templates-dir <path>]
# Exit: 0 spoke scaffolded; 1 validation/usage error; 2 clobber refusal.
# R-23: bash 3.2 compatible.
set -u

# SHARED work-CLAUDE.md renderers — the SINGLE source of truth for the work
# spoke's CLAUDE.md body shape. This is a frozen cross-tool interface: the
# register path (scaffold.sh below) and the adopt path (project.sh's
# _proj_adopt_mint_identity, which SOURCES this file) MUST emit a byte-identical
# work CLAUDE.md. Edit the shape HERE only.
# The work CLAUDE.md carries project identity, a README/updates pointer, a binder
# pointer (cross-plan state), and an AUTO-MAINTAINED directory map bounded by the
# work-map:start / work-map:end sentinels. The map block is generated:true —
# re-derived by the work directory-map generator, never hand-edited. NO @import,
# NO plan roster (the project binder owns that — disjoint roles).
# Usage: _pw_emit_flat_claude_md <spoke> > <out>   (or to a path via redirection)
#        _pw_emit_master_claude_md <spoke> > <out>
_pw_emit_flat_claude_md() {
  local spoke="$1"
  cat <<EOF
# $spoke — spoke context

This is a \`work/\` spoke (project workspace).

<!-- work-map:start generated:true -->
## What lives where

- \`deliverables/\` — polished, audience-facing work.
- \`reference/\` — raw notes / source material.
- \`README.md\` — scope / outcome / definition-of-done.
- \`updates.md\` — append-only updates log.

_Auto-maintained by \`librarian work-map-generate\` — do not hand-edit this block._
<!-- work-map:end -->

\`README.md\` carries scope / outcome / definition-of-done; \`updates.md\` is the
append-only updates log.

Cross-plan state (prior decisions, research index, handoff journal) lives in the project
binder at \`~/.claude-plans/_projects/$spoke/\` — read on demand.
EOF
}

_pw_emit_master_claude_md() {
  local spoke="$1"
  cat <<EOF
# $spoke — master spoke context

This is a \`work/\` MASTER spoke (project workspace). It holds NO top-level
\`deliverables/\` or \`reference/\` — each sub-project under this spoke owns its own.

<!-- work-map:start generated:true -->
## What lives where

- Sub-projects: each owns its own \`deliverables/\` (polished, audience-facing work) +
  \`reference/\` (raw notes / source material). This master holds none of its own.
- \`README.md\` — scope / outcome / definition-of-done.
- \`updates.md\` — append-only updates log.

_Auto-maintained by \`librarian work-map-generate\` — do not hand-edit this block._
<!-- work-map:end -->

\`README.md\` carries scope / outcome / definition-of-done; \`updates.md\` is the
append-only updates log.

Cross-plan state (prior decisions, research index, handoff journal) lives in the project
binder at \`~/.claude-plans/_projects/$spoke/\` — read on demand.
EOF
}

# SOURCE-GUARD: when this file is sourced (project.sh reuses the renderers), stop
# here — only the function definitions above are exported, the scaffolding main
# body below never runs. Detection: `return` succeeds ONLY in a sourced context
# (in a directly-run script it errors outside a function). This is context-
# independent (does not depend on BASH_SOURCE/$0 being set) and bash 3.2 safe.
if ( return 0 2>/dev/null ); then
  return 0 2>/dev/null || true   # sourced -> defines-only, no scaffolding.
fi
# Fell through -> invoked directly (bash scaffold.sh ...): run the main body below.

SPOKE=""
WORK_HOME="${BRAIN_STEM_WORK_HOME:-}"
LAYOUT="flat"
SUBDIR=""
TEMPLATES_DIR=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

die() { printf 'scaffold: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --spoke)         SPOKE="${2:-}"; shift 2 ;;
    --work-home)     WORK_HOME="${2:-}"; shift 2 ;;
    --layout)        LAYOUT="${2:-}"; shift 2 ;;
    --subdir)        SUBDIR="${2:-}"; shift 2 ;;
    --templates-dir) TEMPLATES_DIR="${2:-}"; shift 2 ;;
    -h|--help) printf 'Usage: %s --spoke <name> [--work-home <path>] [--layout flat|master] [--subdir <name>] [--templates-dir <path>]\n' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# --- resolve + validate inputs (block-and-log; never partial-write) ----------
[ -n "$SPOKE" ] || die "missing required --spoke <name>"
case "$SPOKE" in */*|.*|"") die "invalid spoke name: '$SPOKE' (no slashes, no leading dot)" ;; esac
[ -n "$WORK_HOME" ] || WORK_HOME="$HOME/work"
case "$LAYOUT" in flat|master) ;; *) die "invalid --layout '$LAYOUT' (expected flat|master)" ;; esac

SPOKE_DIR="$WORK_HOME/$SPOKE"
TODAY="$(date +%F)"

# --- --subdir arm: scaffold an ORGANIZATIONAL-UNIT sub-project under an existing spoke ---
# A sub-project is NOT a full project: it mints README + deliverables/ + reference/
# ONLY — NEVER a CLAUDE.md, NEVER a hub.md. Identity stays with the master.
if [ -n "$SUBDIR" ]; then
  case "$SUBDIR" in */*|.*|"") die "invalid subdir name: '$SUBDIR' (no slashes, no leading dot)" ;; esac
  # the spoke (master) must already exist as a directory.
  [ -d "$SPOKE_DIR" ] || die "spoke dir not found for --subdir: $SPOKE_DIR (create the spoke first)"
  SUB_DIR="$SPOKE_DIR/$SUBDIR"
  # real-dir guard: refuse to clobber a pre-existing real sub-project.
  if [ -e "$SUB_DIR" ] && [ ! -L "$SUB_DIR" ]; then
    die "refusing to clobber existing sub-project: $SUB_DIR" 2
  fi
  mkdir -p "$SUB_DIR/deliverables" "$SUB_DIR/reference" || die "mkdir failed under $SUB_DIR"
  # sub README — carries the one-line launch advisory; NO CLAUDE.md, NO hub.md.
  cat > "$SUB_DIR/README.md" <<EOF
# $SPOKE / $SUBDIR

> Launch from \`~/work/$SPOKE/\`, not here — this sub-project has no launch context of its own.

## Scope

<what this sub-project covers>

## Outcome

<the deliverable(s) this sub-project produces>

## Definition of done

<how you know it is finished>
EOF
  printf 'scaffold: created sub-project %s under spoke %s at %s\n' "$SUBDIR" "$SPOKE" "$SUB_DIR"
  printf '  shape   : README.md deliverables/ reference/ (no CLAUDE.md, no hub.md — organizational unit)\n'
  exit 0
fi

# real-dir guard: refuse to clobber a pre-existing real spoke (mirrors build-brain-vault).
if [ -e "$SPOKE_DIR" ] && [ ! -L "$SPOKE_DIR" ]; then
  die "refusing to clobber existing spoke: $SPOKE_DIR" 2
fi

# --- Seam 1: folder scaffolding ---------------------------------------------
# MASTER layout holds NO top-level deliverables/reference (each sub-project owns its own);
# FLAT layout (default) holds the raw↔polished split at the top level.
if [ "$LAYOUT" = "master" ]; then
  mkdir -p "$SPOKE_DIR" || die "mkdir failed under $SPOKE_DIR"
else
  mkdir -p "$SPOKE_DIR/deliverables" "$SPOKE_DIR/reference" || die "mkdir failed under $SPOKE_DIR"
fi

# CLAUDE.md — the work spoke's identity + on-demand pointer surface, rendered via the
# SHARED renderers above (the SINGLE source of truth the adopt path also calls).
if [ "$LAYOUT" = "master" ]; then
  _pw_emit_master_claude_md "$SPOKE" > "$SPOKE_DIR/CLAUDE.md"
else
  _pw_emit_flat_claude_md "$SPOKE" > "$SPOKE_DIR/CLAUDE.md"
fi

# README + updates — minimal shape stubs (the foundation scaffolds the shape only; the
# flat MVP ships NO starter templates per — the adopter owns the body content).
cat > "$SPOKE_DIR/README.md" <<EOF
# $SPOKE

## Scope

<what this spoke covers>

## Outcome

<the deliverable(s) this spoke produces>

## Definition of done

<how you know it is finished>
EOF
cat > "$SPOKE_DIR/updates.md" <<EOF
# $SPOKE — updates

Append-only running log of status, risks, and decisions (newest last).

## $TODAY

- Spoke scaffolded.
EOF

# --- summary -----------------------------------------------------------------
printf 'scaffold: created spoke %s at %s\n' "$SPOKE" "$SPOKE_DIR"
if [ "$LAYOUT" = "master" ]; then
  printf '  shape   : CLAUDE.md README.md updates.md (MASTER — no top-level deliverables/reference)\n'
else
  printf '  shape   : CLAUDE.md README.md updates.md deliverables/ reference/\n'
fi
exit 0
