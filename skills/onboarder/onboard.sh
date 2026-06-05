#!/usr/bin/env bash
# skills/onboarder/onboard.sh — Tier-2 GA onboarding orchestrator.
#
# Chains the six slim producers (self-contained skill) into the Tier-2 GA path:
#   1. scripts/section-a-slim.sh        -> user-fragment-A.json  (deterministic discovery)
#   2. scripts/section-b-slim.sh        -> user-fragment-B.json  (voice-optional; 2-pass LLM extract)
#   3. scripts/bootstrap-user-manifest.sh -> user-manifest.json (merge + validate + atomic)
#   4. scripts/author-claude-home.sh    -> $CLAUDE_HOME/CLAUDE.md
#   5. scripts/build-brain-vault.sh     -> <vault>/ tree + <vault>/CLAUDE.md
#   6. scripts/external-setup-gate.sh   -> external-setup-state.json (soft-mandate)
#
# NO `/adopt` call. NO Tier-3 machinery (auto-author surfaces, seed-content intake,
# infer-vault chain, archetype-inference, opt-outs) — Tier-3 is entirely out of
# brain-stem (no onboard-tier3.sh in the skill).
#
# Resume model: $USER_MANIFEST `.system.onboarding_complete` (schema 2.0.0),
# NOT the dropped `.system.phases_completed[]` A–E model.
#
# Modes:
#   default                Interactive. Section B yields rc=5 at the LLM-extraction
#                          handoff; the caller (LLM driving /onboard, or a harness)
#                          runs the extraction model on the staged prompt, then
#                          re-invokes with `--resume --extraction-stub PATH`.
#   --extraction-stub PATH Supply the Section-B extraction output directly; the
#                          chain runs end-to-end in one shot (no rc=5 yield).
#   --resume               Resume the two-pass chain (paired with --extraction-stub).
#   --typed-only           Force typed input for Section B (skip the voice probe).
#   --skip-external-setup  Skip the soft-mandate external-setup gate (step 6).
#   --dry-run              Emit per-step would-run handoffs; zero filesystem writes.
#   --force                Re-onboard past the onboarding_complete sentinel;
#                          also forwarded to bootstrap + the CLAUDE.md writers.
#
# Single-use lifecycle: a BARE /onboard with
# `.system.onboarding_complete == true` no-ops (exit 0); --force re-onboards.
#
# Passthrough (forwarded to build-brain-vault.sh):
#   --vault-root PATH | --plans-home PATH | --skills-dir PATH | --force
#
# Self-contained skill: the producers resolve via $SELF_DIR/scripts; the
# shared foundation assets (schema / templates / vault-init) resolve via their
# install-co-owned $CLAUDE_HOME homes. No REPO_ROOT grandparent walk. OUTPUT targets
# also live under $CLAUDE_HOME.
#
# Exit codes:
#   0   pipeline complete | resume no-op | dry-run
#   2   bad invocation / missing dependency
#   3   producer I/O / render / write failure
#   5   paused at Section-B extraction handoff (state on disk; re-invoke to resume)
#   130 user quit during a section
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`, no `${var,,}`.

set -eu

# -----------------------------------------------------------------------
# Resolve paths.
# -----------------------------------------------------------------------
: "${CLAUDE_HOME:=$HOME/.claude}"
: "${INPUTS_DIR:=$CLAUDE_HOME/onboarding}"
: "${USER_MANIFEST:=$CLAUDE_HOME/user-manifest.json}"
: "${TRANSCRIPT_DIR:=$INPUTS_DIR/transcripts}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Self-contained skill: the producers live in this skill's scripts/ dir.
ONBOARDING_ROOT="$SELF_DIR/scripts"

# Foundation inputs (shared assets STAY in their install-co-owned $CLAUDE_HOME homes).
SCHEMA="$CLAUDE_HOME/schemas/user-manifest-schema.json"
HOME_TEMPLATE="$CLAUDE_HOME/templates/claude-home-claude-md-template.md"
VAULT_TEMPLATE="$CLAUDE_HOME/templates/vault-claude-md-template.md"
VAULT_INIT="$CLAUDE_HOME/vault-init"

# Producer scripts (all six in scripts/).
SECTION_A="$ONBOARDING_ROOT/section-a-slim.sh"
SECTION_B="$ONBOARDING_ROOT/section-b-slim.sh"
BOOTSTRAP="$ONBOARDING_ROOT/bootstrap-user-manifest.sh"
AUTHOR_HOME="$ONBOARDING_ROOT/author-claude-home.sh"
BUILD_VAULT="$ONBOARDING_ROOT/build-brain-vault.sh"
EXTERNAL_GATE="$ONBOARDING_ROOT/external-setup-gate.sh"

# Sanity check the six producers exist before doing anything.
for required in "$SECTION_A" "$SECTION_B" "$BOOTSTRAP" "$AUTHOR_HOME" \
                "$BUILD_VAULT" "$EXTERNAL_GATE"; do
  if [ ! -f "$required" ]; then
    printf 'onboard.sh: required Tier-2 producer missing: %s\n' "$required" >&2
    exit 2
  fi
done

# -----------------------------------------------------------------------
# argv parsing.
# -----------------------------------------------------------------------
RESUME=0
EXTRACTION_STUB=""
TYPED_ONLY=0
SKIP_EXTERNAL=0
DRY_RUN=0
VAULT_ROOT_ARG=""
PLANS_HOME_ARG=""
SKILLS_DIR_ARG=""
FORCE=0

usage() { sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --resume)            RESUME=1 ;;
    --extraction-stub)   shift; [ $# -gt 0 ] || { echo "onboard.sh: --extraction-stub requires a path" >&2; exit 2; }; EXTRACTION_STUB="$1" ;;
    --typed-only)        TYPED_ONLY=1 ;;
    --skip-external-setup) SKIP_EXTERNAL=1 ;;
    --dry-run)           DRY_RUN=1 ;;
    --vault-root)        shift; [ $# -gt 0 ] || { echo "onboard.sh: --vault-root requires a path" >&2; exit 2; }; VAULT_ROOT_ARG="$1" ;;
    --plans-home)        shift; [ $# -gt 0 ] || { echo "onboard.sh: --plans-home requires a path" >&2; exit 2; }; PLANS_HOME_ARG="$1" ;;
    --skills-dir)        shift; [ $# -gt 0 ] || { echo "onboard.sh: --skills-dir requires a path" >&2; exit 2; }; SKILLS_DIR_ARG="$1" ;;
    --force)             FORCE=1 ;;
    -h|--help)           usage ;;
    *)                   echo "onboard.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# -----------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------
log() { printf 'onboard.sh: %s\n' "$*" >&2; }

emit_handoff() {
  # Structured handoff signal read by the LLM-driven /onboard flow + harnesses.
  printf '# HANDOFF: %s\n' "$*"
}

onboarding_complete() {
  [ -f "$USER_MANIFEST" ] || return 1
  jq -e '.system.onboarding_complete == true' "$USER_MANIFEST" >/dev/null 2>&1
}

# -----------------------------------------------------------------------
# Step runners.
# -----------------------------------------------------------------------
run_section_a() {
 # --resume re-entry (+ the --resume half of):
  # Section A is deterministic + idempotent pure discovery, and emit_fragment
  # (section-a-slim.sh:150) atomically OVERWRITES user-fragment-A.json — so a
  # naive re-run on --resume would re-probe the host and wipe any Pass-1 identity
  # corrections. The point of --resume is to re-enter at the extraction handoff,
 # not to re-discover identity (documented --resume re-entry contract).
  # This is also the only read of RESUME (closing the dead-flag half of
 # onboard.sh:107 sets it but it was never consumed).
  if [ "$RESUME" -eq 1 ] && [ -f "$INPUTS_DIR/user-fragment-A.json" ]; then
    log "Section A — resuming; keeping staged user-fragment-A.json"
    return 0
  fi
  log "Section A — discovery review"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run section-a-slim"; return 0; }
  bash "$SECTION_A" --inputs-dir "$INPUTS_DIR"
}

run_section_b() {
  log "Section B — who you are + behavioral prose (voice-optional)"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run section-b-slim"; return 0; }

  # Build the section-b-slim argv.
  set -- --inputs-dir "$INPUTS_DIR" --transcript-dir "$TRANSCRIPT_DIR"
  [ "$TYPED_ONLY" -eq 1 ] && set -- "$@" --typed-only

  # Stub supplied (CLI flag or env): run the whole two-pass section in one shot.
  local stub="$EXTRACTION_STUB"
  [ -z "$stub" ] && stub="${EXTRACTION_OUTPUT_OVERRIDE:-}"
  if [ -n "$stub" ]; then
    # Propagate section-b's rc — do NOT swallow it with an unconditional return 0
    # (mirrors the interactive branch's rc handling below). A swallowed exit 3
    # here would let run_bootstrap proceed with no user-fragment-B.json and latch
 #.system.onboarding_complete=true with B silently dropped.
    set +e
    EXTRACTION_OUTPUT_OVERRIDE="$stub" bash "$SECTION_B" "$@"
    local rc=$?
    set -e
    [ "$rc" -eq 0 ] || { log "Section B (one-shot stub) failed rc=$rc"; exit "$rc"; }
    return 0
  fi

  # Interactive: run Pass 1; rc=5 means awaiting extraction → emit HANDOFF, exit 5.
  set +e
  bash "$SECTION_B" "$@"
  local rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then
    log "Section B — Pass 1 complete; awaiting LLM extraction"
    emit_handoff "extract-section-B resume-with=\"--resume --extraction-stub <path>\""
    exit 5
  elif [ "$rc" -ne 0 ]; then
    log "Section B failed rc=$rc"
    exit "$rc"
  fi
}

run_bootstrap() {
  log "Finalize — bootstrap-user-manifest (merge A+B → user-manifest.json)"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run bootstrap-user-manifest"; return 0; }
 # Producer-output gate (DURABLE class fix): bootstrap treats
  # Section B as OPTIONAL (bootstrap-user-manifest.sh:169 merges B only when present)
  # and latches .system.onboarding_complete=true once A alone validates (:196), so
  # ANY path that loses B silently would latch onboarding complete with role/org/
  # behavioral prose dropped. Assert B exists AND is non-empty before bootstrap runs,
  # consistent with the six-producer existence-check pattern above.
  if [ ! -s "$INPUTS_DIR/user-fragment-B.json" ]; then
    log "Section B fragment missing or empty: $INPUTS_DIR/user-fragment-B.json — refusing to bootstrap (would drop behavioral prose)."
    exit 3
  fi
 # do NOT force unconditionally — a careless re-onboard must not silently
  # clobber a differing manifest. Forward --force only when the user passed it.
  set -- --inputs-dir "$INPUTS_DIR" --schema "$SCHEMA" --out "$USER_MANIFEST"
  [ "$FORCE" -eq 1 ] && set -- "$@" --force
  bash "$BOOTSTRAP" "$@"
}

run_author_home() {
  log "Author — \$CLAUDE_HOME/CLAUDE.md"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run author-claude-home"; return 0; }
  set -- --user-manifest "$USER_MANIFEST" --template "$HOME_TEMPLATE" --target "$CLAUDE_HOME/CLAUDE.md"
  [ "$FORCE" -eq 1 ] && set -- "$@" --force
  bash "$AUTHOR_HOME" "$@"
}

run_build_vault() {
  log "Build — brain vault (tree + <vault>/CLAUDE.md)"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run build-brain-vault"; return 0; }
  set -- --user-manifest "$USER_MANIFEST" --template "$VAULT_TEMPLATE" --vault-init "$VAULT_INIT"
  [ -n "$VAULT_ROOT_ARG" ] && set -- "$@" --vault-root "$VAULT_ROOT_ARG"
  [ -n "$PLANS_HOME_ARG" ] && set -- "$@" --plans-home "$PLANS_HOME_ARG"
  [ -n "$SKILLS_DIR_ARG" ] && set -- "$@" --skills-dir "$SKILLS_DIR_ARG"
  [ "$FORCE" -eq 1 ] && set -- "$@" --force
  bash "$BUILD_VAULT" "$@"
}

run_external_gate() {
  if [ "$SKIP_EXTERNAL" -eq 1 ]; then
    log "External setup — skipped via --skip-external-setup"
    return 0
  fi
  log "External setup — soft-mandate gate (claude-mem / GitHub)"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run external-setup-gate"; return 0; }
  bash "$EXTERNAL_GATE"
}

# -----------------------------------------------------------------------
# Main control flow.
# -----------------------------------------------------------------------
# Single-use lifecycle: the onboarding_complete sentinel gates a BARE invoke
# (not only --resume). A bare /onboard with .system.onboarding_complete == true no-ops;
# a real re-onboard requires the explicit --force escape hatch.
if [ "$FORCE" -ne 1 ] && onboarding_complete; then
  log "Onboarding already complete (system.onboarding_complete == true) — nothing to do."
  log "Re-run with --force to re-onboard."
  exit 0
fi

mkdir -p "$INPUTS_DIR" "$TRANSCRIPT_DIR"

run_section_a
run_section_b      # may exit 5 at the extraction handoff (interactive mode)
run_bootstrap
run_author_home
run_build_vault
run_external_gate

log "Tier-2 onboarding complete."
exit 0
