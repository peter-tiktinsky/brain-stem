#!/bin/bash
# skills/onboarder/scripts/section-b-slim.sh — Tier-2 slim Section B'.
#
# The single voice-optional transcript section of the slim interview. Section A
# is deterministic (section-a-slim.sh); Section C was cut (operator decision
# Clusters defer to the runtime propose-and-validate folder
# flow, vault rules are hand-edited into the vault CLAUDE.md). B' captures
# free-form input (long-winded is fine) and runs a SLIM LLM extraction that
# CONSOLIDATES it into the tight, template-ready manifest fields: identity.role,
# identity.organization, and the three behavioral prose blocks.
#
# Slim fork of section-b.sh: KEEPS the voice-capture -> typed-textarea fallback
# + two-pass extraction mechanism; DROPS the Tier-3 machinery (confidence-gate
# routing, opt-out surfaces, archetype handoff, projects/people/cadence/audience).
#
# Two-pass flow (production caller = Claude inside the harness):
#   Pass 1: capture transcript (idempotent), render the compiled extraction
#           prompt to $INPUTS_DIR/extraction-prompt-B-slim.txt, exit 5.
#   Pass 2 (EXTRACTION_OUTPUT_OVERRIDE set): read the model's nested-JSON
#           output, wrap into user-fragment-B.json (atomic), append a
#           structural-only JSONL audit line, exit 0.
#
# Hermetic test mode (single pass): set STDIN_TRANSCRIPT_OVERRIDE (transcript)
# + EXTRACTION_OUTPUT_OVERRIDE (staged model output) + --typed-only.
#
# Output fragment (consumed by bootstrap-user-manifest.sh):
#   { "section_id": "B", "populated": { "identity": {...}, "behavioral": {...} },
#     "notes": "<string|null>" }
#   populated = the extraction output minus `notes`; the slim writer's schema
#   validation (additionalProperties:false) is the backstop for stray keys.
#
# Hard invariants (mirror section-b.sh): bash 3.2 + R-23; atomic tmp+rename;
# reference-leak floor (NO user strings in audit diagnostic fields).
#
# Args: --typed-only | --inputs-dir DIR | --audit-log PATH | --transcript-dir DIR
#       | --prompt-card PATH | --extraction-template PATH
# Env:  INPUTS_DIR, AUDIT_LOG, TRANSCRIPT_DIR, VOICE_CAPTURE_BIN,
#       TYPED_TEXTAREA_BIN, EXTRACTION_OUTPUT_OVERRIDE, STDIN_TRANSCRIPT_OVERRIDE,
#       VOICE_PROBE_OVERRIDE
# Exit: 0 success | 2 bad invocation/dep | 3 write/validation error
#       | 5 extraction needed (Pass 1 done) | 130 user quit

set -u

diag() { printf 'section-b-slim FAIL: %s\n' "$1" >&2; }
info() { printf 'section-b-slim: %s\n' "$1" >&2; }

PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

for tool in jq date python3; do
  command -v "$tool" >/dev/null 2>&1 || { diag "$tool required but not on PATH"; exit 2; }
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Self-contained skill: the read-on-demand references live alongside the
# producer at skills/onboarder/references/ (scripts/ -> skill root -> references/).
REFERENCES_DIR="$(cd "$SCRIPT_DIR/../references" && pwd)"

INPUTS_DIR="${INPUTS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding}"
AUDIT_LOG="${AUDIT_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/section-b-slim.jsonl}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/transcripts}"
# Raw-capture bins: typed-textarea.sh is the shipped Tier-2 minimum-viable rung;
# voice-capture.sh is a future add-on (env-overridable). When BOTH are absent,
# capture does NOT silently succeed — it emits the documented rc=5 driver-staging
# handoff (stage your answer at $TRANSCRIPT_PATH, then re-invoke --extraction-stub
# <path> one-shot or --resume; see capture_transcript). The GA two-pass flow stages
# the transcript + EXTRACTION_OUTPUT_OVERRIDE, so capture_transcript short-circuits
# before reaching these bins.
VOICE_CAPTURE_BIN="${VOICE_CAPTURE_BIN:-$SCRIPT_DIR/voice-capture.sh}"
TYPED_TEXTAREA_BIN="${TYPED_TEXTAREA_BIN:-$SCRIPT_DIR/fallback/typed-textarea.sh}"
PROMPT_CARD="$REFERENCES_DIR/prompt-cards/section-b-slim.txt"
EXTRACTION_TEMPLATE="$REFERENCES_DIR/extraction-prompts/section-B-slim.md"
TYPED_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --typed-only)          TYPED_ONLY=1; shift ;;
    --inputs-dir)          INPUTS_DIR="$2"; shift 2 ;;
    --audit-log)           AUDIT_LOG="$2"; shift 2 ;;
    --transcript-dir)      TRANSCRIPT_DIR="$2"; shift 2 ;;
    --prompt-card)         PROMPT_CARD="$2"; shift 2 ;;
    --extraction-template) EXTRACTION_TEMPLATE="$2"; shift 2 ;;
    -h|--help)             sed -n '2,46p' "$0"; exit 0 ;;
    *)                     diag "unknown arg: $1"; exit 2 ;;
  esac
done

[ -r "$PROMPT_CARD" ]         || { diag "prompt card not readable: $PROMPT_CARD"; exit 2; }
[ -r "$EXTRACTION_TEMPLATE" ] || { diag "extraction template not readable: $EXTRACTION_TEMPLATE"; exit 2; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TRANSCRIPT_PATH="$TRANSCRIPT_DIR/section-b-slim.txt"
COMPILED_PROMPT="$INPUTS_DIR/extraction-prompt-B-slim.txt"
FRAGMENT_OUT="$INPUTS_DIR/user-fragment-B.json"

mkdir -p "$INPUTS_DIR" "$TRANSCRIPT_DIR" "$(dirname "$AUDIT_LOG")" 2>/dev/null \
  || { diag "cannot create output directories"; exit 3; }

# --- Pass 1: transcript capture (idempotent; voice -> typed fallback) ---
capture_transcript() {
  if [ -f "$TRANSCRIPT_PATH" ]; then
    info "transcript already present at $TRANSCRIPT_PATH; skipping capture"
    return 0
  fi
  # Driver/test staging channel (documented at :23-24): when STDIN_TRANSCRIPT_OVERRIDE
  # is set and no transcript is staged yet, write its contents to $TRANSCRIPT_PATH and
  # skip capture entirely (no bin invocation). Load-bearing only on the non-stub path —
  # in the single-pass stub seam main() short-circuits before capture (see :212).
  if [ -n "${STDIN_TRANSCRIPT_OVERRIDE:-}" ]; then
    printf '%s' "$STDIN_TRANSCRIPT_OVERRIDE" > "$TRANSCRIPT_PATH" \
      || { diag "STDIN_TRANSCRIPT_OVERRIDE stage failed"; return 3; }
    info "transcript staged from STDIN_TRANSCRIPT_OVERRIDE at $TRANSCRIPT_PATH"
    return 0
  fi
  # No capture bin is executable on this host (the GA clean-install state): rather
  # than fail cryptically (rc=127 -> rc=3), degrade to the documented driver-staging
  # handoff — return 5 (the established awaiting-driver-action rc, symmetric with the
  # Pass-1 exit 5 and onboard.sh's :167 rc=5 handling).
  if [ ! -x "$VOICE_CAPTURE_BIN" ] && [ ! -x "$TYPED_TEXTAREA_BIN" ]; then
    info "no capture bin available; stage your Section B answer at $TRANSCRIPT_PATH, then re-invoke --extraction-stub <path> (one-shot) or --resume after the model extracts."
    return 5
  fi
  if [ "$TYPED_ONLY" = "1" ]; then
    TRANSCRIPT_DIR="$TRANSCRIPT_DIR" "$TYPED_TEXTAREA_BIN" b "$PROMPT_CARD" >/dev/null
    _relocate_transcript $?; return $?
  fi
  # Deterministic voice-availability switch (documented at :38-39): when
  # VOICE_PROBE_OVERRIDE declares voice unavailable, skip the real voice probe and
  # force rc=4 so the 'voice unavailable -> typed' branch below is reachable in tests
  # without a real voice bin.
  case "${VOICE_PROBE_OVERRIDE:-}" in
    0|unavailable) rc=4 ;;
    *) TRANSCRIPT_DIR="$TRANSCRIPT_DIR" "$VOICE_CAPTURE_BIN" b "$PROMPT_CARD" >/dev/null
       rc=$? ;;
  esac
  case "$rc" in
    0)   _relocate_transcript 0; return $? ;;
    4)   info "voice unavailable; dispatching to typed-textarea"
         TRANSCRIPT_DIR="$TRANSCRIPT_DIR" "$TYPED_TEXTAREA_BIN" b "$PROMPT_CARD" >/dev/null
         _relocate_transcript $?; return $? ;;
    127) info "capture bin present but not runnable (rc=127); stage your Section B answer at $TRANSCRIPT_PATH, then re-invoke --extraction-stub <path> (one-shot) or --resume after the model extracts."
         return 5 ;;
    130) info "user quit during capture"; return 130 ;;
    *)   diag "transcript capture failed (rc=$rc)"; return 3 ;;
  esac
}

# voice-capture/typed-textarea write to $TRANSCRIPT_DIR/section-b.txt; the slim
# flow uses section-b-slim.txt to avoid colliding with the Tier-3 transcript.
_relocate_transcript() {
  local rc="$1"
  [ "$rc" -eq 0 ] || return "$rc"
  local src="$TRANSCRIPT_DIR/section-b.txt"
  if [ -f "$src" ] && [ "$src" != "$TRANSCRIPT_PATH" ]; then
    mv -f "$src" "$TRANSCRIPT_PATH" || { diag "transcript relocate failed"; return 3; }
  fi
  [ -f "$TRANSCRIPT_PATH" ] || { diag "no transcript produced at $TRANSCRIPT_PATH"; return 3; }
  return 0
}

# --- Pass 1: render compiled extraction prompt ---
# Extract the FIRST fenced ``` block from the template (the literal prompt),
# then substitute the single <<<{transcript}>>> site.
render_compiled_prompt() {
  local raw_prompt="$INPUTS_DIR/.prompt-B-slim.tmp.$$"
  awk '
    /^```/ { fence++; next }
    fence == 1 { print }
  ' "$EXTRACTION_TEMPLATE" > "$raw_prompt"
  if [ ! -s "$raw_prompt" ]; then
    diag "could not extract fenced prompt block from $EXTRACTION_TEMPLATE"
    rm -f "$raw_prompt"; return 3
  fi
  python3 -c '
import sys
prompt_f, transcript_f, out_f = sys.argv[1:]
def rd(p):
    with open(p, "r", encoding="utf-8") as f: return f.read()
t = rd(prompt_f).replace("<<<{transcript}>>>", rd(transcript_f))
with open(out_f, "w", encoding="utf-8") as f: f.write(t)
' "$raw_prompt" "$TRANSCRIPT_PATH" "$COMPILED_PROMPT" || {
    diag "compiled-prompt render failed"; rm -f "$raw_prompt"; return 3; }
  rm -f "$raw_prompt"
  return 0
}

# --- Pass 2: wrap extraction output into the fragment ---
process_extraction() {
  local extract_in="$1"
  jq -e . "$extract_in" >/dev/null 2>&1 || { diag "extraction output not valid JSON"; return 3; }
  jq -e 'type == "object"' "$extract_in" >/dev/null 2>&1 \
    || { diag "extraction output must be a JSON object"; return 3; }

  # populated = extraction output minus `notes`. Allowed-key guard.
  local stray
  stray="$(jq -r '[keys[] | select(. != "identity" and . != "behavioral" and . != "notes")] | join(",")' "$extract_in")"
  if [ -n "$stray" ]; then
    diag "extraction output has unexpected top-level key(s): $stray"
    return 3
  fi

  local notes_json populated_json
  notes_json="$(jq -c '.notes // null' "$extract_in")"
  populated_json="$(jq -c 'del(.notes)' "$extract_in")"

  local tmp="$FRAGMENT_OUT.tmp.$$"
  jq -nc --argjson populated "$populated_json" --argjson notes "$notes_json" \
    '{section_id: "B", populated: $populated, notes: $notes}' > "$tmp" \
    || { diag "fragment render failed"; rm -f "$tmp"; return 3; }
  mv "$tmp" "$FRAGMENT_OUT" || { diag "fragment rename failed"; rm -f "$tmp"; return 3; }

  # --- structural-only JSONL audit (manifest_paths_written = populated keys) ---
  jq -nc --arg section_id "B" --arg run_id "$RUN_ID" --arg ts "$RUN_TS" \
    --argjson manifest_paths "$(jq -c '.populated | keys' "$FRAGMENT_OUT")" \
    '{section_id:$section_id, run_id:$run_id, ts:$ts,
      manifest_paths_written:$manifest_paths}' >> "$AUDIT_LOG" \
    || { diag "audit append failed"; return 3; }
  return 0
}

# --- main ---
# One-shot --extraction-stub (EXTRACTION_OUTPUT_OVERRIDE set): the driver has
# already run Pass 1 out-of-band, so the compiled prompt is irrelevant and there
# is no transcript to capture. Skip capture + render entirely and go straight to
# process_extraction below — capture-free, render-free. Capturing first here would
# fire with no transcript + absent bins (rc=5/3) before the stub is ever read.
if [ -z "${EXTRACTION_OUTPUT_OVERRIDE:-}" ]; then
  capture_transcript
  case "$?" in
    0)   : ;;
    5)   info "capture unavailable; awaiting driver-staged transcript (exit 5)."; exit 5 ;;
    130) info "section-b aborted at user request."; exit 130 ;;
    *)   exit 3 ;;
  esac

  render_compiled_prompt || exit 3
fi

if [ -n "${EXTRACTION_OUTPUT_OVERRIDE:-}" ]; then
  [ -r "$EXTRACTION_OUTPUT_OVERRIDE" ] || { diag "EXTRACTION_OUTPUT_OVERRIDE not readable"; exit 2; }
  process_extraction "$EXTRACTION_OUTPUT_OVERRIDE" || exit 3
  info "Section B fragment committed at $FRAGMENT_OUT"
  exit 0
fi

info "compiled extraction prompt staged at $COMPILED_PROMPT"
info "Pass 1 complete. Run the extraction model on it, then re-invoke with"
info "EXTRACTION_OUTPUT_OVERRIDE=<model-output.json> to commit user-fragment-B.json."
exit 5
