#!/bin/bash
# skills/onboarder/scripts/section-a-slim.sh — Tier-2 slim Section A.
#
# Deterministic discovery-confirmation card for the four Section-A fields the
# v3 Tier-2 interview needs: name, email, timezone, vault root. This is the
# slim fork of section-a.sh — it DROPS fields 5-11 (tool detection +
# workflow archetype fields), which are Tier-3 (out of scope:
# zero Tier-3 capture reaches the interview surface).
#
# No transcript, no LLM, no confidence gates. Pure UX-state-to-JSON pass over
# read-only host probes (Bucket C). Writes:
#   1. $INPUTS_DIR/user-fragment-A.json   (nested .populated slice consumed by
#                                          bootstrap-user-manifest.sh)
#   2. $AUDIT_LOG                          (JSONL; structural metadata only)
#
# Hard invariants (mirror section-a.sh):
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,}).
#   - JSONL audit emits structural metadata only — no user strings in fields.
#   - Probes are READ-ONLY against the live host.
#   - Timezone probe uses readlink /etc/localtime (CFF-S56-5; privilege-free).
#
# Env knobs (override defaults; tests + dogfood):
#   AUTO_ACCEPT=1          Non-interactive Enter-accept-all.
#   INPUTS_DIR             Where user-fragment-A.json lands
#                          (default: $CLAUDE_HOME/onboarding).
#   AUDIT_LOG              JSONL audit path
#                          (default: $CLAUDE_HOME/onboarding/audit/section-a-slim.jsonl).
#   SLIM_A_NAME/_EMAIL/_TZ/_VAULT
#                          Hermetic-test value injection (bypass the probe for
#                          that field). SLIM_A_VAULT="none" => no-vault.
#
# Exit codes: 0 success | 2 bad invocation / missing dependency | 3 write error
#             | 130 user quit

set -u

diag() { printf 'section-a-slim FAIL: %s\n' "$1" >&2; }
info() { printf 'section-a-slim: %s\n' "$1" >&2; }

PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

for tool in jq date; do
  command -v "$tool" >/dev/null 2>&1 || { diag "$tool required but not on PATH"; exit 2; }
done

INPUTS_DIR="${INPUTS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding}"
AUDIT_LOG="${AUDIT_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/section-a-slim.jsonl}"
AUTO_ACCEPT="${AUTO_ACCEPT:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --inputs-dir) INPUTS_DIR="$2"; shift 2 ;;
    --audit-log)  AUDIT_LOG="$2"; shift 2 ;;
    --auto-accept) AUTO_ACCEPT=1; shift ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *)            diag "unknown arg: $1"; exit 2 ;;
  esac
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FRAGMENT_OUT="$INPUTS_DIR/user-fragment-A.json"

mkdir -p "$INPUTS_DIR" "$(dirname "$AUDIT_LOG")" 2>/dev/null || {
  diag "cannot create output directories"; exit 3; }

# --- discovery probes (read-only; test overrides win) ---
probe_name() {
  [ -n "${SLIM_A_NAME:-}" ] && { printf '%s\n' "$SLIM_A_NAME"; return 0; }
  git config --global user.name 2>/dev/null
}
probe_email() {
  [ -n "${SLIM_A_EMAIL:-}" ] && { printf '%s\n' "$SLIM_A_EMAIL"; return 0; }
  git config --global user.email 2>/dev/null
}
probe_timezone() {
  [ -n "${SLIM_A_TZ:-}" ] && { printf '%s\n' "$SLIM_A_TZ"; return 0; }
  readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||'
}
# Tier-2 ALWAYS builds a fresh "brain" vault. This is
# not an existing-vault scan — it proposes WHERE to create the brain vault.
# Default: $HOME/Documents/brain (Obsidian-friendly). User edits or sets "none"
# to defer the location to the build step.
probe_vault_root() {
  if [ -n "${SLIM_A_VAULT:-}" ]; then
    [ "$SLIM_A_VAULT" = "none" ] && { printf '\n'; return 0; }
    printf '%s\n' "$SLIM_A_VAULT"; return 0
  fi
  printf '%s\n' "$HOME/Documents/brain"
}

V_NAME="$(probe_name)"
V_EMAIL="$(probe_email)"
V_TZ="$(probe_timezone)"
V_VAULT="$(probe_vault_root)"

CORRECTIONS=""
note_correction() {
  case " $CORRECTIONS " in *" $1 "*) ;; *) CORRECTIONS="${CORRECTIONS}${CORRECTIONS:+ }$1" ;; esac
}

fmt() { [ -z "$1" ] && printf '(none detected)' || printf '%s' "$1"; }
fmt_vault() {
  [ -z "$1" ] && printf '(decide at build time)' || printf '%s' "$1"
}

display_card() {
  printf '\n=== Section A — Welcome & Discovery Review ===\n\n' >&2
  printf "Here's what we already know. Confirm or correct.\n\n" >&2
  printf '  1. Name:           %s\n' "$(fmt "$V_NAME")" >&2
  printf '  2. Email:          %s\n' "$(fmt "$V_EMAIL")" >&2
  printf '  3. Timezone:       %s\n' "$(fmt "$V_TZ")" >&2
  printf '  4. Brain vault at: %s\n' "$(fmt_vault "$V_VAULT")" >&2
  printf "\nWe'll build a fresh \"brain\" vault for you at the location above.\n" >&2
  printf '\n[Enter] = accept all   1-4 = edit field   q = quit\n> ' >&2
}

edit_field() {
  case "$1" in
    1) printf 'Name (blank = keep): ' >&2; read -r v; [ -n "$v" ] && { V_NAME="$v"; note_correction 1; } ;;
    2) printf 'Email (blank = keep): ' >&2; read -r v; [ -n "$v" ] && { V_EMAIL="$v"; note_correction 2; } ;;
    3) printf 'Timezone (IANA, e.g. America/New_York; blank = keep): ' >&2; read -r v; [ -n "$v" ] && { V_TZ="$v"; note_correction 3; } ;;
    4) printf 'Brain vault location (absolute path, or "none" to decide later; blank = keep): ' >&2; read -r v
       if [ "$v" = "none" ]; then V_VAULT=""; note_correction 4
       elif [ -n "$v" ]; then V_VAULT="$v"; note_correction 4; fi ;;
    *) info "field $1 out of range (1-4)" ;;
  esac
}

emit_fragment() {
  local tmp="$FRAGMENT_OUT.tmp.$$"
  jq -n \
    --arg name "$V_NAME" --arg email "$V_EMAIL" --arg tz "$V_TZ" --arg vault "$V_VAULT" \
    '{
      section_id: "A",
      populated: {
        identity: {
          name:  (if $name  == "" then null else $name  end),
          email: (if $email == "" then null else $email end)
        },
        system: { timezone: (if $tz == "" then null else $tz end) },
        paths:  { vault_root: (if $vault == "" then null else $vault end) },
        vault:  { root: (if $vault == "" then null else $vault end) }
      }
    }' > "$tmp" || return 1
  mv "$tmp" "$FRAGMENT_OUT" || return 1
}

emit_audit() {
  local corrections_json
  if [ -z "$CORRECTIONS" ]; then corrections_json='[]'
  else corrections_json="$(printf '%s\n' $CORRECTIONS | jq -R 'tonumber' | jq -s .)"; fi
  # manifest paths actually populated (structural; no user strings).
  local paths_json
  paths_json="$(jq -nc \
    --argjson have_name  "$([ -n "$V_NAME" ]  && echo true || echo false)" \
    --argjson have_email "$([ -n "$V_EMAIL" ] && echo true || echo false)" \
    --argjson have_tz    "$([ -n "$V_TZ" ]    && echo true || echo false)" \
    --argjson have_vault "$([ -n "$V_VAULT" ] && echo true || echo false)" \
    '[ (if $have_name then "identity.name" else empty end),
       (if $have_email then "identity.email" else empty end),
       (if $have_tz then "system.timezone" else empty end),
       (if $have_vault then "paths.vault_root" else empty end) ]')"
  jq -nc --arg section_id "A" --arg run_id "$RUN_ID" --arg ts "$RUN_TS" \
    --argjson corrections "$corrections_json" --argjson manifest_paths "$paths_json" \
    '{section_id:$section_id, run_id:$run_id, ts:$ts, corrections:$corrections,
      manifest_paths_written:$manifest_paths}' >> "$AUDIT_LOG" || return 1
}

commit_and_exit() {
  emit_fragment || { diag "fragment write failed"; exit 3; }
  emit_audit    || { diag "audit write failed"; exit 3; }
  info "Section A complete. user-fragment-A.json staged at $FRAGMENT_OUT."
  exit 0
}

if [ "$AUTO_ACCEPT" = "1" ]; then
  commit_and_exit
fi

while :; do
  display_card
  if ! IFS= read -r choice; then printf '\n' >&2; commit_and_exit; fi
  case "$choice" in
    "")        commit_and_exit ;;
    q|Q)       info "Section A aborted at user request."; exit 130 ;;
    [1-4])     edit_field "$choice" ;;
    *)         info "Invalid input: '$choice'. Press Enter, 1-4, or q." ;;
  esac
done
