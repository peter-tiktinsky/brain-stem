#!/bin/bash
# scaffold.sh — project-workspace, Seam-1 folder scaffolding for a work/ spoke.
# The executable half of recipe.md.
# Writes ONLY under $WORK_HOME/<spoke>/ (the adopter's work spoke); it reads the
# foundation hub template read-only and NEVER modifies a foundation file. That is the
# load-bearing "zero foundation edits" property the recipe proves.
# OUTPUT CONTRACT:
#   files written : --layout flat (default) → $WORK_HOME/<spoke>/{CLAUDE.md, hub.md,
#                   README.md, updates.md} + deliverables/ + reference/ (dirs) — the
#                   6-file MVP shape (no starters).
#                   --layout master → $WORK_HOME/<spoke>/{CLAUDE.md, hub.md, README.md,
#                   updates.md} ONLY — NO top-level deliverables/ or reference/ (each
#                   sub-project owns its own); hub.md renders the MASTER variant (block 7
#                   points at sub-projects).
#                   --subdir <name> → $WORK_HOME/<spoke>/<name>/{README.md, deliverables/,
#                   reference/} under an existing spoke — NEVER a CLAUDE.md, NEVER a hub.md
#                   (sub-projects are ORGANIZATIONAL UNITS, identity stays with the master,
#   schema        : hub.md follows the foundation hub template (type: index, 8 pointer
#                   blocks); README/updates are free-form spoke docs the adopter owns.
#   pre-write validation : a resolvable templates dir (for hub.md); refuses to clobber a
#                   pre-existing real spoke dir; --subdir requires the spoke dir to already
#                   exist + a slash-free <name>.
#   failure mode  : block-and-log — validate all inputs first, diagnostic to stderr, non-zero
#                   exit; never partial-write over an existing spoke.
# Usage: scaffold.sh --spoke <name> [--work-home <path>]
#                    [--layout flat|master] [--subdir <name>]
#                    [--templates-dir <path>]
# Exit: 0 spoke scaffolded; 1 validation/usage error; 2 clobber refusal.
# R-23: bash 3.2 compatible.
set -u

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

# templates dir: explicit > $CLAUDE_HOME/templates > repo templates/ (script-relative)
if [ -z "$TEMPLATES_DIR" ]; then
  if [ -n "${CLAUDE_HOME:-}" ] && [ -d "$CLAUDE_HOME/templates" ]; then
    TEMPLATES_DIR="$CLAUDE_HOME/templates"
  else
    TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../../../.." 2>/dev/null && pwd)/templates"
  fi
fi
HUB_TEMPLATE="$TEMPLATES_DIR/hub-template.md"
[ -f "$HUB_TEMPLATE" ] || die "hub template not found: $HUB_TEMPLATE (pass --templates-dir)"

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

# hub.md rendered from the foundation hub template (read-only consume): substitute the
# spoke name + today's date. The template is the propagation surface for the 8-block set.
# For MASTER, block 7 (Deliverables) is rewritten in place to point at sub-projects — the
# master holds none (a conditional block in the scaffolder, not a separate template file).
if [ "$LAYOUT" = "master" ]; then
  sed -e "s/<spoke>/$SPOKE/g" -e "s/<YYYY-MM-DD>/$TODAY/g" "$HUB_TEMPLATE" \
    | awk '
        /^## 7\. Deliverables/ {
          print "## 7. Deliverables"
          print ""
          print "- Sub-projects: each owns its own `deliverables/` + `reference/`; this master holds none."
          print "- This is a MASTER project — its top-level surface organizes sub-projects, which carry the work product. (Pointer-only; sub-project bodies are read on-demand, never inlined here.)"
          skip = 1
          next
        }
        /^## 8\. / { skip = 0 }
        skip == 1 { next }
        { print }
      ' > "$SPOKE_DIR/hub.md" || die "failed to render master hub.md"
else
  sed -e "s/<spoke>/$SPOKE/g" -e "s/<YYYY-MM-DD>/$TODAY/g" "$HUB_TEMPLATE" > "$SPOKE_DIR/hub.md" \
    || die "failed to render hub.md"
fi

# CLAUDE.md — the eager cover-page bridge; <=30 lines, imports hub.md (import directive
# lives here, never inside hub.md — import is CLAUDE.md-only Claude Code behavior).
if [ "$LAYOUT" = "master" ]; then
  cat > "$SPOKE_DIR/CLAUDE.md" <<EOF
# $SPOKE — master spoke context

@hub.md

This is a \`work/\` MASTER spoke (project workspace). \`hub.md\` is the eager pointer-only
cover page imported above; \`README.md\` is the context doc (scope / outcome /
definition-of-done); \`updates.md\` is the append-only updates log. This master holds NO
top-level \`deliverables/\` or \`reference/\` — each sub-project under this spoke owns its
own. Read sub-project bodies on-demand — they are not imported here.
EOF
else
  cat > "$SPOKE_DIR/CLAUDE.md" <<EOF
# $SPOKE — spoke context

@hub.md

This is a \`work/\` spoke (project workspace). \`hub.md\` is the eager pointer-only cover
page imported above; \`README.md\` is the context doc (scope / outcome / definition-of-done);
\`updates.md\` is the append-only updates log. Polished, audience-facing work lives in
\`deliverables/\`; raw notes and source material live in \`reference/\`. Read deliverable and
reference bodies on-demand — they are not imported here.
EOF
fi

# README + updates — minimal shape stubs (the foundation scaffolds the shape only; the
# 6-file MVP ships NO starter templates per — the adopter owns the body content).
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
  printf '  shape   : CLAUDE.md hub.md README.md updates.md (MASTER — no top-level deliverables/reference)\n'
else
  printf '  shape   : CLAUDE.md hub.md README.md updates.md deliverables/ reference/\n'
fi
exit 0
