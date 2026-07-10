#!/bin/bash
# Hook: SessionStart (#8) — force-ingest the per-spoke GENERATED situating card so
# a session SELF-ORIENTS the instant it opens in a work spoke / project binder.
# This is the LOAD side of the project-context-surfaces engine (T-07/T-11):
#   1. Read the SessionStart payload `.cwd` (the launch dir; NEVER
#      $CLAUDE_PROJECT_DIR). Graceful no-op when `.cwd` is absent/empty.
#   2. Resolve launch-dir -> spoke via spoke_resolve_from_cwd (skills/new-plan/
#      lib/spoke-resolve.sh — the SHARED resolver, not a reimplementation). The
#      home anchor resolves to the literal `home` catch-all.
#   3. (T-11) REFRESH-FROM-DISK before ingest: re-derive the resolved spoke's
#      situating card so an out-of-band edit (a human / external tool since the
#      last session-close — the PostToolUse gap that never fires outside a Claude
#      session) is reflected in what the model sees THIS session. The refresh is
#      scoped to the SINGLE resolved spoke and budget-bounded so it stays inside
#      the SessionStart timeout. It does NOT use session-start-integrity-backstop.sh
#      (that is crash-only — not the staleness vehicle).
#   4. (T-07) FORCE-INGEST the card {PLANS_ROOT}/_projects/<spoke>/_situating.md as
#      additionalContext via format_output (NOT format_output_allow): the card is
#      PRE-BOUNDED < 9728B by the generator (Round A), so no truncation guard is
#      needed; format_output_allow would re-truncate a card already within budget.
# Graceful no-op (exit 0, emit NOTHING — never an empty injection, never a crash;
# degrade to the install.sh rule fallback) when: `.cwd` is absent, no spoke
# resolves, or no card exists on disk. A SessionStart hook that non-zero-exits or
# emits a malformed payload can break the user's session — fail-open always.
# Bash 3.2 clean (R-23). Argv-based Python heredoc per R-24 (the shared resolver
# passes data via argv). $SCRIPT_DIR/lib sourcing (portable; no $HOME/.claude
# body literal). Honors PLANS_ROOT/PLANS_DIR + SPOKE_REGISTRY_PATH for isolation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"

# registry.sh provides format_output (+ sources paths.sh -> PLANS_DIR). Source the
# repo-local lib first (dev/test), then the live install — mirrors the sibling
# hooks. Fail-open: if format_output never lands we cannot inject, so exit clean.
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null \
  || source "$CLAUDE_HOME_RES/hooks/lib/registry.sh" 2>/dev/null \
  || exit 0

# The shared cwd->spoke resolver (skills/new-plan/lib/spoke-resolve.sh). Source the
# repo-local copy first, then the live install. Absent -> nothing to resolve.
for _sr in "$_REPO_ROOT/skills/new-plan/lib/spoke-resolve.sh" \
           "$CLAUDE_HOME_RES/skills/new-plan/lib/spoke-resolve.sh"; do
  if [ -r "$_sr" ]; then source "$_sr"; break; fi
done
unset _sr
command -v spoke_resolve_from_cwd >/dev/null 2>&1 || exit 0

# Plans home (the binder root). PLANS_ROOT/PLANS_DIR override, else paths.sh value.
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

# --- 1. read the SessionStart payload .cwd (the launch dir — NOT $CLAUDE_PROJECT_DIR) -------
# Drain stdin once so we never block. The .cwd is the session's launch dir.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

command -v jq >/dev/null 2>&1 || exit 0
CWD=""
if [ -n "$INPUT" ]; then
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi
EVENT="SessionStart"
if [ -n "$INPUT" ]; then
  _e=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
  [ -n "$_e" ] && EVENT="$_e"
  unset _e
fi

# Graceful no-op: no launch dir -> cannot key a spoke (degrade to the rule fallback).
[ -z "$CWD" ] && exit 0

# --- 2. resolve launch-dir -> spoke (shared resolver; home anchor -> `home`) ----
# spoke_resolve_from_cwd prints the spoke key on stdout (diagnostics on stderr,
# non-zero on a registry collision). On any non-zero / empty result -> no-op.
SPOKE=$(spoke_resolve_from_cwd "$CWD" 2>/dev/null) || exit 0
[ -z "$SPOKE" ] && exit 0

CARD="$PLANS_ROOT/_projects/$SPOKE/_situating.md"

# --- 3-pre. refresh-from-disk the 3 binder md generators -
# The T-11 backstop below re-derives the situating card + work-map + work-index, but
# NOT the 3 binder markdown generators (plan-research-index / plan-decision-log /
# plan-handoff-index) — so an out-of-band binder edit since last close (a plan
# manifest / research / decision artifact touched by a human or external tool) was
# uncorrected at session start. Run the 3 generators FIRST, so the situating card
# re-derive below reads their FRESH output — the card-after-generators ordering that
# post-manifest-binder-refresh.sh already encodes (research -> decision -> handoff ->
# card). Best-effort / fail-open: a failed/absent binder refresh must never block the
# situating-card ingest or crash SessionStart. Scoped via --spoke to stay inside the
# SessionStart timeout; PLANS_ROOT carries through for test isolation.
for _bindergen in plan-research-index plan-decision-log plan-handoff-index; do
  _bg_cap=""
  for _c in "$_REPO_ROOT/skills/librarian/capabilities/${_bindergen}.sh" \
            "$CLAUDE_HOME_RES/skills/librarian/capabilities/${_bindergen}.sh"; do
    if [ -f "$_c" ]; then _bg_cap="$_c"; break; fi
  done
  unset _c
  if [ -n "$_bg_cap" ] && [ -f "$_bg_cap" ]; then
    PLANS_ROOT="$PLANS_ROOT" FINDINGS_OUTPUT="/dev/null" \
      bash "$_bg_cap" --spoke "$SPOKE" >/dev/null 2>&1 || true
  fi
done
unset _bindergen _bg_cap

# --- 3. (T-11) refresh-from-disk BEFORE ingest (scoped to the single spoke) -----
# Re-derive the resolved spoke's situating card so an out-of-band edit since last
# close is reflected in the force-loaded card. Scoped via --spoke to stay inside
# the SessionStart timeout; no-op cleanly when the spoke has no binder yet. This is
# the staleness backstop — NOT the crash-only integrity backstop. Best-effort:
# a failed/absent refresh must never block the ingest of a card already on disk.
SITUATING_CAP="${SITUATING_CAP:-}"
if [ -z "$SITUATING_CAP" ]; then
  for _c in "$_REPO_ROOT/skills/librarian/capabilities/project-context-situating.sh" \
            "$CLAUDE_HOME_RES/skills/librarian/capabilities/project-context-situating.sh"; do
    if [ -f "$_c" ]; then SITUATING_CAP="$_c"; break; fi
  done
  unset _c
fi
if [ -n "$SITUATING_CAP" ] && [ -f "$SITUATING_CAP" ]; then
  # The generator self-skips a spoke with no contributing plans (no binder yet) and
  # is block-and-log internally; suppress its findings stream + ignore its rc so the
  # refresh never derails the ingest. PLANS_ROOT carries through for test isolation.
  PLANS_ROOT="$PLANS_ROOT" FINDINGS_OUTPUT="/dev/null" \
    bash "$SITUATING_CAP" --spoke "$SPOKE" >/dev/null 2>&1 || true
fi

# --- 3b. (T-15) best-effort work-map refresh-from-disk (the WORK surface) -------
# Also re-derive the resolved spoke's work-map directory-map block in the work
# CLAUDE.md, so an out-of-band file edit since last close (the PostToolUse gap that
# never fires outside a Claude session) is reflected in the work surface this session.
# This writes to $WORK_HOME (NOT PLANS_ROOT — disjoint root), so resolve + pass
# WORK_HOME (scaffold.sh order: WORK_HOME -> BRAIN_STEM_WORK_HOME -> $HOME/work) for
# test isolation. Best-effort: a leave-orphan / absent-spoke skip must never block the
# session — suppress findings, ignore rc, fail-open.
WORK_HOME="${WORK_HOME:-${BRAIN_STEM_WORK_HOME:-$HOME/work}}"
case "$WORK_HOME" in */) WORK_HOME="${WORK_HOME%/}" ;; esac
WORKMAP_CAP="${WORKMAP_CAP:-}"
if [ -z "$WORKMAP_CAP" ]; then
  for _c in "$_REPO_ROOT/skills/librarian/capabilities/work-map-generate.sh" \
            "$CLAUDE_HOME_RES/skills/librarian/capabilities/work-map-generate.sh"; do
    if [ -f "$_c" ]; then WORKMAP_CAP="$_c"; break; fi
  done
  unset _c
fi
if [ -n "$WORKMAP_CAP" ] && [ -f "$WORKMAP_CAP" ]; then
  WORK_HOME="$WORK_HOME" FINDINGS_OUTPUT="/dev/null" \
    bash "$WORKMAP_CAP" --spoke "$SPOKE" >/dev/null 2>&1 || true
fi

# --- 3c. best-effort work-index refresh-from-disk (the WORK folder indexes) ------
# Also mint/refresh the resolved spoke's deliverables/ + reference/ _index.md
# contents-enum tables from disk, so an out-of-band file add/remove since last close
# is reflected in the work folder indexes this session. Writes to $WORK_HOME (same
# root as the work-map above; disjoint from PLANS_ROOT). Best-effort: an absent spoke /
# target subfolder / marker-less index skip must never block the session — suppress
# findings, ignore rc, fail-open.
WORKINDEX_CAP="${WORKINDEX_CAP:-}"
if [ -z "$WORKINDEX_CAP" ]; then
  for _c in "$_REPO_ROOT/skills/librarian/capabilities/work-index-maintain.sh" \
            "$CLAUDE_HOME_RES/skills/librarian/capabilities/work-index-maintain.sh"; do
    if [ -f "$_c" ]; then WORKINDEX_CAP="$_c"; break; fi
  done
  unset _c
fi
if [ -n "$WORKINDEX_CAP" ] && [ -f "$WORKINDEX_CAP" ]; then
  WORK_HOME="$WORK_HOME" FINDINGS_OUTPUT="/dev/null" \
    bash "$WORKINDEX_CAP" --spoke "$SPOKE" >/dev/null 2>&1 || true
fi

# --- 4. (T-07) force-ingest the card as additionalContext (format_output) -------
# Graceful no-op when the card does not exist (a spoke with no binder, or a refresh
# that produced nothing) — emit NOTHING, never an empty injection.
[ -f "$CARD" ] || exit 0
[ -s "$CARD" ] || exit 0

CARD_BODY=$(cat "$CARD" 2>/dev/null || true)
[ -z "$CARD_BODY" ] && exit 0

# format_output (NOT _allow): the card is pre-bounded < 9728B by the generator, so
# no truncation guard is wanted; _allow would silently corrupt an in-budget card.
format_output "$EVENT" "$CARD_BODY" || exit 0
exit 0
