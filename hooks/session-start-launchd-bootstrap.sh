#!/bin/bash
# Hook: SessionStart — bootstrap-reconcile the two foundation launchd jobs.
#
# The two shipped launchd lanes (writer-reconciler + doc-amender) are STAGED at
# install time by render-launchd.sh --staging-dir, which deliberately skips
# `launchctl bootstrap` because a non-Aqua install shell cannot reliably bootstrap
# gui/$UID (the reason --staging-dir exists). This hook fires inside a real
# Aqua-context session — a domain where bootstrap works — detects any
# staged-but-unloaded foundation label via `launchctl print gui/$UID/<label>`
# (the same liveness primitive the cron-health banner uses), and bootstraps the
# staged plist for each unloaded label. It generalizes the production-bootstrap
# pattern in skills/doc-amender/install-watch.sh to BOTH foundation jobs.
#
# Advisory-only: ALWAYS exits 0. It skips cleanly when a label is already loaded
# (no redundant bootstrap), when no staged plist exists, or when the GUI domain is
# unreachable (a non-Aqua/headless shell). A SessionStart hook that non-zero-exits
# can break the session, so every path returns 0.
#
# Test seam (fixtures only; production uses the real launchctl + install layout):
#   SESSION_LAUNCHD_BOOTSTRAP_LAUNCHCTL   launchctl to invoke (default: launchctl)
#   LAUNCHD_STAGING_DIR                   staged-plist dir override
#   LABEL_PREFIX                          label namespace (default: com.brain-stem)
#
# Bash 3.2 clean (R-23).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# paths.sh resolves CLAUDE_HOME; sourcing is best-effort (never break the session).
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || true

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

CH="${CLAUDE_HOME:-$HOME/.claude}"
LAUNCHCTL="${SESSION_LAUNCHD_BOOTSTRAP_LAUNCHCTL:-launchctl}"
LABEL_PREFIX="${LABEL_PREFIX:-com.brain-stem}"
uid="$(id -u 2>/dev/null || echo 0)"
domain="gui/$uid"

# Bootstrap requires a reachable GUI domain. On a non-Aqua shell there is none —
# skip cleanly rather than emit launchctl errors.
if ! { command -v "$LAUNCHCTL" >/dev/null 2>&1 || [ -x "$LAUNCHCTL" ]; }; then
  exit 0
fi
"$LAUNCHCTL" print "$domain" >/dev/null 2>&1 || exit 0

# Candidate staged-plist dirs, in resolution order:
#   1. explicit override (tests / bespoke installs)
#   2. the install.sh next-step staging target ($CLAUDE_HOME/Library/LaunchAgents.staging)
#   3. the production render target (~/Library/LaunchAgents) — a plist rendered
#      there but never bootstrapped
staged_plist_for() {  # $1 = label ; echoes the first staged plist path found, else empty
  local label="$1" d
  for d in "${LAUNCHD_STAGING_DIR:-}" \
           "$CH/Library/LaunchAgents.staging" \
           "$HOME/Library/LaunchAgents"; do
    [ -n "$d" ] || continue
    if [ -f "$d/$label.plist" ]; then printf '%s' "$d/$label.plist"; return 0; fi
  done
  return 1
}

for lane in writer-reconciler doc-amender; do
  label="${LABEL_PREFIX}.${lane}"

  # Already loaded -> skip (no redundant bootstrap).
  if "$LAUNCHCTL" print "$domain/$label" >/dev/null 2>&1; then
    continue
  fi

  # Unloaded: bootstrap the staged plist if one exists.
  plist="$(staged_plist_for "$label")" || continue
  "$LAUNCHCTL" bootstrap "$domain" "$plist" >/dev/null 2>&1 || true
done

exit 0
