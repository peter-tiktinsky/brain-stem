#!/bin/bash
# Hook: SessionStart (#4) — onboarding-resume detect.
#
# SessionStart fire-order #4:
# session-register -> cron-health-banner -> spec-context-inject -> session-start
# -> memory-seed. A single-use lifecycle governs the resume path.
# Reads user-manifest.json :: system.onboarding_complete:
#   - incomplete (false / null / no manifest): surface a resume prompt as
#     additionalContext (the onboarding flow has not finished — invite /onboard
#     --resume).
#   - complete (true): no-op silently (the onboarder is single-use; the
#     model never auto-fires a re-onboard).
#
# This hook NEVER mutates the manifest + NEVER auto-invokes
# /onboard — it only surfaces the resume affordance. NEVER denies; exits 0.
# (Any plan-status read elsewhere would key on the canonical `status` —
# this body reads only the manifest boolean, no status vocabulary involved.)
set -uo pipefail

# Portability: resolve libs via $SCRIPT_DIR. user-manifest-read
# provides the canonical read API; registry provides format_output_allow.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0
[ -r "$SCRIPT_DIR/lib/user-manifest-read.sh" ] && source "$SCRIPT_DIR/lib/user-manifest-read.sh" 2>/dev/null
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

# Resolve onboarding_complete. Prefer the canonical read API (umr_get_string);
# fall back to a direct jq read of the resolved manifest path.
ONBOARDING_COMPLETE=""
if command -v umr_get_string >/dev/null 2>&1; then
  ONBOARDING_COMPLETE="$(umr_get_string '.system.onboarding_complete' 2>/dev/null || true)"
else
  MANIFEST="${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
  if [ -r "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
    ONBOARDING_COMPLETE="$(jq -r '.system.onboarding_complete // empty' "$MANIFEST" 2>/dev/null || true)"
  fi
fi

# Complete -> no-op silently.
if [ "$ONBOARDING_COMPLETE" = "true" ]; then
  exit 0
fi

# Incomplete (false / null / empty / no manifest) -> surface the resume prompt.
resume_text="[Onboarding] brain-stem onboarding has not been completed (system.onboarding_complete is not true). Run /onboard --resume to finish setup (fills the two CLAUDE.md files + builds your brain vault). This banner clears once onboarding completes."

if command -v format_output_allow >/dev/null 2>&1; then
  format_output_allow "SessionStart" "$resume_text" || true
else
  printf '%s\n' "$resume_text" >&2
fi

exit 0
