#!/bin/bash
# skills/onboarder/scripts/fallback/typed-textarea.sh — Tier-2 typed-capture rung.
#
# The minimum-viable typed-input rung for Section B' (voice is a future add-on
# per section-b-slim.sh:66). Invoked by section-b-slim.sh capture_transcript()
# as: `TRANSCRIPT_DIR=<dir> typed-textarea.sh b <prompt-card>`.
#
# Renders the prompt card to STDERR (the caller redirects this script's stdout
# to /dev/null and reads the transcript file), then captures a free-form answer
# and writes it to $TRANSCRIPT_DIR/section-b.txt — exactly the path
# _relocate_transcript in section-b-slim.sh reads (it mv's that file to
# $TRANSCRIPT_PATH).
#
# Input behavior (honors `[ -t 0 ]`):
#   - piped / non-TTY stdin → consume the piped bytes as the transcript, exit 0
#   - interactive TTY        → read multi-line input until Ctrl-D, exit 0
#   - no stdin at all (empty capture) → fall through to the rc=5 driver-staging
#     handoff (the established awaiting-driver-action rc) rather than blocking or
#     writing an empty transcript. section-b-slim.sh's _relocate_transcript
#     propagates this rc=5 up to its main, which exits 5.
#
# Self-contained skill: this bin lives under the onboarder skill's own
# scripts/fallback/; no grandparent walk, no REPO_ROOT=../.. coupling.
#
# Hard invariants: bash 3.2 + R-23 (no declare -A, no mapfile, no ${var,,});
# atomic tmp+rename; reference-leak floor (no user transcript text in stderr).
#
# Args: b <prompt-card-path>   (positional; section id then the prompt card)
# Env:  TRANSCRIPT_DIR (output dir; default $CLAUDE_HOME/onboarding/transcripts)
# Exit: 0 transcript captured + written | 2 bad invocation/dep
#       | 3 write error | 5 no input staged → driver-staging handoff

set -u

diag() { printf 'typed-textarea FAIL: %s\n' "$1" >&2; }
info() { printf 'typed-textarea: %s\n' "$1" >&2; }

# --- source paths.sh if present (post-install runtime); fall back to env ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

# --- defaults ---
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/transcripts}"
SECTION_ID=""
PROMPT_CARD_PATH=""

# --- arg parsing (positional: section id, then prompt-card path) ---
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    -*)        diag "unknown flag: $1"; exit 2 ;;
    *)
      if [ -z "$SECTION_ID" ]; then
        SECTION_ID="$1"
      elif [ -z "$PROMPT_CARD_PATH" ]; then
        PROMPT_CARD_PATH="$1"
      else
        diag "unexpected positional arg: $1"
        exit 2
      fi
      shift ;;
  esac
done

# --- validate SECTION_ID (Section B is the slim minimum-viable rung) ---
if [ -z "$SECTION_ID" ]; then
  diag "section id required (b)"
  exit 2
fi
SECTION_ID="$(printf '%s' "$SECTION_ID" | tr '[:upper:]' '[:lower:]')"

# --- validate PROMPT_CARD_PATH ---
if [ -z "$PROMPT_CARD_PATH" ]; then
  diag "prompt-card path required"
  exit 2
fi
if [ ! -r "$PROMPT_CARD_PATH" ]; then
  diag "prompt-card path not readable: $PROMPT_CARD_PATH"
  exit 2
fi

# --- output path: the exact src section-b-slim's _relocate_transcript reads ---
TRANSCRIPT_PATH="$TRANSCRIPT_DIR/section-${SECTION_ID}.txt"
mkdir -p "$TRANSCRIPT_DIR" 2>/dev/null || { diag "cannot create $TRANSCRIPT_DIR"; exit 3; }

# --- render the prompt card to STDERR (stdout is the caller's /dev/null) ---
printf '\n' >&2
cat "$PROMPT_CARD_PATH" >&2
printf '\n' >&2

# --- capture: piped bytes (non-TTY) or interactive Ctrl-D (TTY) ---
if [ -t 0 ]; then
  info "Typed input mode — enter your response below; press Ctrl-D when done."
else
  info "Typed input mode — reading transcript from stdin until EOF."
fi
TRANSCRIPT_TEXT="$(cat)"

# --- no input at all → driver-staging handoff (rc=5), never an empty write ---
if [ -z "$TRANSCRIPT_TEXT" ]; then
  info "no typed input captured; stage your Section B answer, then re-invoke --extraction-stub <path> (one-shot) or --resume after the model extracts."
  exit 5
fi

# --- atomic tmp+rename write ---
TMP_PATH="${TRANSCRIPT_PATH}.tmp.$$"
printf '%s\n' "$TRANSCRIPT_TEXT" > "$TMP_PATH" || { diag "tmp write failed"; rm -f "$TMP_PATH"; exit 3; }
mv -f "$TMP_PATH" "$TRANSCRIPT_PATH" || { diag "rename failed"; rm -f "$TMP_PATH"; exit 3; }

info "transcript captured at $TRANSCRIPT_PATH"
exit 0
