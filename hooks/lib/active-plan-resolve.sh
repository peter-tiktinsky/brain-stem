#!/bin/bash
# hooks/lib/active-plan-resolve.sh — resolve "the armed plan of THIS spoke".
#
# Source it — do not execute it:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/active-plan-resolve.sh"
#   armed="$(resolve_active_target_for_spoke "$PLANS_ROOT" "$spoke")"
#
# WHY PER-SPOKE. The arm pointer records which plan a session is building, and every
# reader treats it as "the active plan". A single pointer for the whole plan corpus
# makes that a machine-wide claim: whichever spoke armed last owns the answer for
# EVERY session, so a session launched in another spoke is handed a foreign plan's
# spec as authoritative, a spoke with nothing armed is handed one anyway, and two
# spokes can never hold an arm at the same time. The pointer therefore lives in the
# spoke's own binder directory, and a reader resolves it for the spoke it is anchored
# to. The spoke key is supplied by the caller — this file never guesses it.
#
# RESOLUTION ORDER
#   1. <plans_root>/_projects/<spoke>/.active-plan — the spoke's own pointer. It wins
#      whenever it names an existing plan directory.
#   2. <plans_root>/.active-plan — the LEGACY corpus-wide pointer. Read-only here:
#      nothing in this chain writes it. It is accepted
#        - for the `home` catch-all spoke, UNFILTERED — an install that has never
#          armed per-spoke keeps today's behaviour exactly; and
#        - for a registered spoke, ONLY when the plan it names carries no `project`
#          in its manifest, or a `project` equal to that spoke. A plan armed for
#          another spoke stays invisible here.
#   3. otherwise unarmed (the empty string).
#   A pointer naming a directory that does not exist degrades to the next step, so a
#   dangling per-spoke pointer falls through to the legacy one and a dangling legacy
#   pointer resolves to unarmed.
#
# The <plan>/.active-sp leg is unchanged: it names the armed sub-plan, and a '.'
# value, an absent file or a dangling sub-plan resolves to the plan root.
#
# CONTRACT. Read-only: nothing here creates, writes or removes a file, and nothing
# outside <plans_root> is read. NEVER errors: every fallible command is guarded and
# every function returns 0, because callers run under `set -euo pipefail`, where an
# unguarded non-zero inside a sourced function aborts the CALLER instead of resolving
# to "unarmed". An unarmed spoke prints the empty string.
#
# Bash 3.2 clean. No hard external dependency: the manifest `project` read prefers jq
# and falls back to python3, and a tree carrying neither reads as "no project" — the
# lenient side of the filter, so a missing tool degrades to today's behaviour rather
# than to a spurious "nothing is armed".

# active_plan_pointer_path <plans_root> <spoke>
# Print the spoke's own pointer path. Pure string composition — it does not test for
# the file, so a writer can use it as a create target and a reader as a probe.
active_plan_pointer_path() {
  printf '%s' "${1:-}/_projects/${2:-}/.active-plan"
  return 0
}

# resolve_active_plan_for_spoke <plans_root> <spoke>
# Print the armed plan slug for this spoke, or the empty string when unarmed.
resolve_active_plan_for_spoke() {
  local plans_root="${1:-}" spoke="${2:-}"
  local ptr="" plan="" manifest="" project=""
  if [ -z "$plans_root" ] || [ -z "$spoke" ]; then
    printf ''
    return 0
  fi

  # 1. the spoke's own pointer.
  ptr="$(active_plan_pointer_path "$plans_root" "$spoke")"
  if [ -f "$ptr" ]; then
    plan="$(tr -d '[:space:]' < "$ptr" 2>/dev/null || printf '')"
    if [ -n "$plan" ] && [ -d "$plans_root/$plan" ]; then
      printf '%s' "$plan"
      return 0
    fi
  fi

  # 2. the legacy corpus-wide pointer — unfiltered for `home`, project-filtered for a
  #    registered spoke.
  ptr="$plans_root/.active-plan"
  if [ -f "$ptr" ]; then
    plan="$(tr -d '[:space:]' < "$ptr" 2>/dev/null || printf '')"
    if [ -n "$plan" ] && [ -d "$plans_root/$plan" ]; then
      if [ "$spoke" = "home" ]; then
        printf '%s' "$plan"
        return 0
      fi
      manifest="$plans_root/$plan/manifest.json"
      project=""
      if [ -f "$manifest" ]; then
        if command -v jq >/dev/null 2>&1; then
          project="$(jq -r '.project // ""' "$manifest" 2>/dev/null || printf '')"
        elif command -v python3 >/dev/null 2>&1; then
          project="$(python3 -c 'import sys,json
try:
    print(json.load(open(sys.argv[1])).get("project","") or "")
except Exception:
    print("")' "$manifest" 2>/dev/null || printf '')"
        fi
      fi
      case "$project" in null) project="" ;; esac
      if [ -z "$project" ] || [ "$project" = "$spoke" ]; then
        printf '%s' "$plan"
        return 0
      fi
    fi
  fi

  # 3. unarmed.
  printf ''
  return 0
}

# resolve_active_target_for_spoke <plans_root> <spoke>
# Print the armed TARGET as a plans-relative path — `.claude-plans/<plan>` or
# `.claude-plans/<plan>/<sp>` — or the empty string when unarmed. The <sp> leg is the
# unchanged <plan>/.active-sp chain: '.', absent, or a dangling sub resolves to the
# plan root, because the plan pointer is still meaningful there.
resolve_active_target_for_spoke() {
  local plans_root="${1:-}" spoke="${2:-}"
  local plan="" sp="" rel=""
  plan="$(resolve_active_plan_for_spoke "$plans_root" "$spoke")"
  if [ -z "$plan" ]; then
    printf ''
    return 0
  fi
  rel=".claude-plans/$plan"
  if [ -f "$plans_root/$plan/.active-sp" ]; then
    sp="$(tr -d '[:space:]' < "$plans_root/$plan/.active-sp" 2>/dev/null || printf '')"
    if [ -n "$sp" ] && [ "$sp" != "." ] && [ -d "$plans_root/$plan/$sp" ]; then
      rel=".claude-plans/$plan/$sp"
    fi
  fi
  printf '%s' "$rel"
  return 0
}
