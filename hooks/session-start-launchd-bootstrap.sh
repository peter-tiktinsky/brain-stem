#!/bin/bash
# Hook: SessionStart — bootstrap-reconcile the two foundation launchd jobs.
#
# The two shipped launchd lanes (writer-reconciler + doc-amender) have their plists
# staged at install time by that render step, render-launchd.sh --staging-dir, which deliberately skips
# `launchctl bootstrap` because a non-Aqua install shell cannot reliably bootstrap
# gui/$UID (the reason --staging-dir exists). This hook fires inside a real
# Aqua-context session — a domain where bootstrap works — detects any
# staged-but-unloaded foundation label via `launchctl print gui/$UID/<label>`
# (the same liveness primitive the cron-health banner uses), and bootstraps the
# staged plist for each unloaded label. It generalizes the production-bootstrap
# pattern in skills/doc-amender/install-watch.sh to BOTH foundation jobs.
# It never renders a plist.
#
# Drift: after each successful bootstrap the hook records the sha256 of the
# bootstrapped plist in $HOOKS_STATE/launchd-bootstrap/<label>.sha256. A loaded
# job whose staged plist no longer matches that marker is re-bootstrapped
# (bootout, then bootstrap), so a changed job definition never keeps running the
# old one unnoticed. A loaded job with no marker gets the staged sha recorded as
# its baseline and is left running (no bootout).
#
# Fail-open, visibly: ALWAYS exits 0, because a SessionStart hook that exits
# non-zero can break the session. It skips cleanly when a label is loaded and
# unchanged, when no staged plist exists, or when the GUI domain is unreachable (a
# non-Aqua/headless shell). Anything it did or could not do (a re-bootstrap, a
# recorded baseline, a failed bootout or bootstrap with its exit code) is reported
# as SessionStart hookSpecificOutput.additionalContext on stdout, one line per
# event. There is no output when nothing happened.
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
# BOUNDED drain: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook chain hangs with zero output. This
# hook also runs under launchd, whose descriptors this process does not control. The
# bound is PER READ: a stream that keeps delivering is never truncated, only silence
# is. HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE; do :; done
  unset _STDIN_WAIT _STDIN_LINE
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

MARKER_DIR=""
[ -n "${HOOKS_STATE:-}" ] && MARKER_DIR="$HOOKS_STATE/launchd-bootstrap"

CTX=""
note() {
  local nl=$'\n'
  CTX="${CTX:+$CTX$nl}$1"
}

write_marker() {  # $1 = label, $2 = sha ; non-zero when the marker could not be written
  [ -n "$MARKER_DIR" ] && [ -n "$2" ] \
    && mkdir -p "$MARKER_DIR" \
    && printf '%s\n' "$2" > "$MARKER_DIR/$1.sha256.tmp" \
    && mv -f "$MARKER_DIR/$1.sha256.tmp" "$MARKER_DIR/$1.sha256"
}

json_escape() {
  local s="$1" nl=$'\n' cr=$'\r' tab=$'\t'
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$nl/\\n}"; s="${s//$cr/\\r}"; s="${s//$tab/\\t}"
  printf '%s' "$s"
}

for lane in writer-reconciler doc-amender; do
  label="${LABEL_PREFIX}.${lane}"

  # No staged plist -> nothing to bootstrap or compare against.
  plist="$(staged_plist_for "$label")" || continue
  staged_sha="$(shasum -a 256 "$plist" | cut -d' ' -f1)"

  if "$LAUNCHCTL" print "$domain/$label" >/dev/null 2>&1; then
    # Loaded: compare the staged plist with the one last bootstrapped.
    if [ -z "$MARKER_DIR" ] || [ -z "$staged_sha" ]; then
      note "launchd: drift check unavailable for $label (no hooks state dir or no plist hash)"
      continue
    fi
    marker="$MARKER_DIR/$label.sha256"
    if [ ! -f "$marker" ]; then
      if write_marker "$label" "$staged_sha"; then
        note "launchd: drift baseline recorded for $label"
      else
        note "launchd: could not record the drift marker for $label"
      fi
      continue
    fi
    [ "$(cat "$marker")" = "$staged_sha" ] && continue

    "$LAUNCHCTL" bootout "$domain/$label" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      note "launchd: bootout of $label failed (rc=$rc); the staged plist changed but the old job is still loaded"
      continue
    fi
    "$LAUNCHCTL" bootstrap "$domain" "$plist" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      note "launchd: bootstrap of $label failed (rc=$rc)"
      continue
    fi
    write_marker "$label" "$staged_sha" || note "launchd: could not record the drift marker for $label"
    note "launchd: re-bootstrapped $label (staged plist changed)"
  else
    # Unloaded: bootstrap the staged plist.
    "$LAUNCHCTL" bootstrap "$domain" "$plist" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      note "launchd: bootstrap of $label failed (rc=$rc)"
      continue
    fi
    write_marker "$label" "$staged_sha" || note "launchd: could not record the drift marker for $label"
  fi
done

if [ -n "$CTX" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$(json_escape "$CTX")"
fi

exit 0
