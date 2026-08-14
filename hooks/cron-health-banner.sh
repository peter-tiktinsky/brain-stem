#!/bin/bash
# Hook: SessionStart (#2) — surface launchd/cron lane health as an advisory banner.
#
# SessionStart fire-order #2 (session-register -> cron-health-banner ->
# spec-context-inject -> session-start -> memory-seed).
# Reports launchd/cron health for the foundation lanes so the operator notices a
# silently-dead background lane at session start.
#
# The lane roster is DERIVED, never named inline (see derive_lane_roster). A
# hardcoded roster shrinks the banner's coverage silently every time a lane is
# added, and because the surfacing contract is silent-on-clean, the absence of a
# warning is then indistinguishable from coverage — a control that cannot see the
# defect is worse than no control.
#
# Three signals, each read from where the lane actually leaves evidence:
#   1. NEVER-LOADED (dead-on-arrival): probe `launchctl print gui/$UID/<label>`
#      for each roster label. A staged-but-never-bootstrapped lane produces no
#      activity at all, so staleness alone can never see it — the liveness probe
#      flags it. Only assessed when the GUI domain is reachable (a non-Aqua /
#      headless shell has none — skip rather than false-flag every lane).
#   2. LANE TYPE: that same `launchctl print` output carries `path = <plist>`, so
#      the trigger shape the renderer already stamped into the plist is in hand
#      and does not have to be re-derived. An INTERVAL lane (StartInterval /
#      StartCalendarInterval) has a guaranteed fire cadence, so elapsed-time-
#      since-last-fire is a valid liveness proxy. A WATCHPATHS-ONLY lane has no
#      such cadence: its activity log's age measures how long the WATCHED PATH has
#      been quiet, which carries no health information. Quiet is not dead.
#   3. STALENESS: read the mtime of the wrapper's TRUE activity signal — the
#      timestamped fire log (<lane>-<ts>.log) + audit log (<lane>-audit.log) the
#      cron wrappers write. The plist StandardOutPath (<lane>-stdout.log) is NEVER
#      written by the wrappers (they redirect all output to the timestamped/audit
#      logs), so reading it was structurally blind; that read is retired here.
#        interval lane    -> stale when the last fire is older than the threshold
#                            (per-lane from the manifest, else the global default).
#        WatchPaths lane  -> stale ONLY IF a watched path's mtime is NEWER than the
#                            last fire (an event arrived and no fire followed).
#
# NOT a liveness signal: `runs` / `last exit code` from launchctl. Measured
# first-hand so it is not rediscovered — a re-bootstrapped label reports
# `runs = 0` and `last exit code = (never exited)` no matter how long the lane has
# actually been in service, because those counters are per-LOAD, not lifetime. The
# two durable signals are the plist's trigger shape and the watched-path-vs-last-
# fire mtime comparison.
#
# Exposure this closes, measured on the reference install (2026-08-10): of the two
# foundation lanes, writer-reconciler renders as WatchPaths + a relaxed hourly
# StartInterval backstop and doc-amender renders as WatchPaths-only. The backstop
# keeps writer-reconciler's activity log warm, so it can never be quiet for 24h;
# the WatchPaths-only lane has nothing keeping it warm. Exposure was therefore 1
# of 2 lanes and DETERMINISTIC, not probabilistic: doc-amender's newest activity
# log was 81h old (> the 24h default, so the banner fired) while its watched path
# had been unchanged since Aug 3 and its last fire exited 0 as a clean no-op.
# Quiet, not dead.
#
# Surfacing contract: emit an additionalContext banner ONLY when a lane looks
# not-loaded or stale; silent/clean pass when every lane is healthy. An ABSENT
# activity log on a LOADED lane is benign (the lane may simply not have fired yet
# on a fresh/quiet install). NEVER denies; always exits 0 — a SessionStart hook
# that non-zero-exits can break the session.
#
# Rejected, and NOT adopted:
#   (a) Raise the staleness threshold (it is manifest-overridable). It trades one
#       wrong answer for another: any threshold high enough to stop false-alarming
#       a legitimately-quiet event-driven lane is high enough to hide a genuinely
#       dead one, which is the banner's entire purpose. The problem is the
#       DIMENSION being measured, not its calibration.
#   (b) Drop the WatchPaths-only lane from the roster. It silences the one lane
#       with no interval backstop — i.e. the lane whose dead/never-loaded state is
#       hardest to notice by any other means, and exactly the lane for which the
#       never-loaded arm is most valuable.
#   (c) Extend the hardcoded list to name today's real lanes. The band-aid form of
#       the same defect: it re-arms the identical failure the moment the next lane
#       ships.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR. registry.sh
# provides format_output_allow; paths.sh provides CLAUDE_LOG_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
# BOUNDED drain: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook chain hangs with zero output. The
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

# Log dir. The inline fallback mirrors the cron wrappers' own default
# ($CLAUDE_STATE_ROOT/logs, XDG ephemeral tier) — it previously pointed at
# $CLAUDE_HOME/logs, a directory the wrappers never write. Unreachable in practice
# (paths.sh exports CLAUDE_LOG_DIR and this hook hard-exits if paths.sh fails to
# source) but a wrong default one `source` failure away from silently reading an
# empty directory.
LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/logs}"

# Staleness window (seconds) for INTERVAL lanes. Manifest-overridable; default 24h.
# A WatchPaths-only lane never reaches this threshold test — see the lane-type
# branch below, which is why the default can stay tight instead of being relaxed
# to accommodate event-driven quiet.
STALE_SECS="${CRON_HEALTH_STALE_SECS:-}"
if [ -z "$STALE_SECS" ] && command -v _manifest_get >/dev/null 2>&1; then
  _v="$(_manifest_get .hooks.cron_health.stale_threshold_secs 2>/dev/null || true)"
  [ -n "$_v" ] && STALE_SECS="$_v"
  unset _v
fi
[ -z "$STALE_SECS" ] && STALE_SECS=86400

# Per-lane threshold overrides. Env seam first (space-separated `lane=secs` pairs,
# so fixtures and CI need no manifest and no jq), then the manifest key
# .hooks.cron_health.lane_thresholds.<lane>, then the global default above.
LANE_STALE_SPEC="${CRON_HEALTH_LANE_STALE_SECS:-}"

# Explicit opt-out: lanes deliberately unwatched. Env seam first, then the manifest
# key .hooks.cron_health.unwatched_lanes (a JSON array or a plain list — both
# normalize to whitespace-separated tokens here).
UNWATCHED_LANES="${CRON_HEALTH_UNWATCHED_LANES:-}"
if [ -z "$UNWATCHED_LANES" ] && command -v _manifest_get >/dev/null 2>&1; then
  UNWATCHED_LANES="$(_manifest_get .hooks.cron_health.unwatched_lanes 2>/dev/null || true)"
fi
UNWATCHED_LANES="$(printf '%s' "$UNWATCHED_LANES" | tr -d '[]"' | tr ',\n' '  ')"

# launchctl liveness seam (mockable for CI, which has no launchd GUI domain).
LAUNCHCTL="${CRON_HEALTH_LAUNCHCTL:-launchctl}"
LABEL_PREFIX="${LABEL_PREFIX:-com.brain-stem}"
uid="$(id -u 2>/dev/null || echo 0)"
domain="gui/$uid"

# Assess liveness only when the GUI domain is actually reachable. A non-Aqua shell
# (ssh / headless) has no gui/$UID domain, so probing every label would false-flag
# them all; when the domain query fails we simply skip the never-loaded check.
launchctl_domain_ok=0
if { command -v "$LAUNCHCTL" >/dev/null 2>&1 || [ -x "$LAUNCHCTL" ]; } \
   && "$LAUNCHCTL" print "$domain" >/dev/null 2>&1; then
  launchctl_domain_ok=1
fi

# --- small helpers -----------------------------------------------------------

# Portable mtime (BSD then GNU stat). Echoes an epoch, or 0.
file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Trim leading + trailing whitespace from $1.
trim_ws() {
  local s="$1" lead
  lead="${s%%[![:space:]]*}"; s="${s#"$lead"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Whitespace-separated membership test: in_list <needle> <list>
in_list() {
  local needle="$1" item
  for item in $2; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# Look up <key> in a "k=v k=v" spec string.
spec_lookup() {
  local key="$1" pair
  for pair in $2; do
    case "$pair" in
      "$key"=*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done
  return 1
}

# Effective staleness threshold for a lane (env spec > manifest > global default).
lane_threshold() {
  local lane="$1" v=""
  v="$(spec_lookup "$lane" "$LANE_STALE_SPEC" || true)"
  if [ -z "$v" ] && command -v _manifest_get >/dev/null 2>&1; then
    v="$(_manifest_get ".hooks.cron_health.lane_thresholds.${lane}" 2>/dev/null || true)"
  fi
  case "$v" in ''|*[!0-9]*) v="$STALE_SECS" ;; esac
  printf '%s' "$v"
}

# Newest mtime of a lane's TRUE activity signal: any <lane>-*.log EXCEPT the
# never-written plist StandardOut/ErrorPath. Echoes an epoch, or empty if none.
newest_activity_mtime() {
  local lane="$1" f base m best=""
  for f in "$LOG_DIR/${lane}-"*.log; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      "${lane}-stdout.log"|"${lane}-stderr.log") continue ;;
    esac
    m=$(file_mtime "$f")
    [ "$m" -gt 0 ] 2>/dev/null || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best="$m"; fi
  done
  printf '%s' "$best"
}

# --- lane roster (DERIVED) ---------------------------------------------------
#
# DEFAULT-ON WITH AN EXPLICIT OPT-OUT, AND NO MIGRATION — the ruling for the
# adopter-visible change this derivation ships (lanes that were silently unwatched
# now warn):
#   * The banner is advisory-only. It never denies, always exits 0, and its worst
#     case is one extra line at session start. Gating a change of that blast radius
#     behind a migration costs more than the change itself.
#   * Warning by default IS the fix. The defect being closed is a control that
#     reported green over lanes it never looked at; shipping this default-OFF would
#     preserve exactly that silence and make the fix a no-op.
#   * The net change in banner volume is bounded, not open-ended: the lane-type
#     branch below REMOVES the one deterministic false alarm on the shipped lane
#     set at the same time as the roster grows.
#   * Deliberately-unwatched lanes get an EXPLICIT opt-out
#     (.hooks.cron_health.unwatched_lanes / CRON_HEALTH_UNWATCHED_LANES) rather
#     than an implicit one. An opt-out an adopter has to name is auditable; a
#     silently-missing roster entry is not.

# Candidate dirs holding rendered-but-possibly-not-loaded plists. The order
# mirrors the SessionStart launchd bootstrap sibling: explicit override, then the
# install staging target, then the production render target.
# CRON_HEALTH_PLIST_DIRS (colon-separated) REPLACES the list outright — that is
# what keeps fixtures off the live tree.
plist_search_dirs() {
  if [ -n "${CRON_HEALTH_PLIST_DIRS:-}" ]; then
    printf '%s' "$CRON_HEALTH_PLIST_DIRS" | tr ':' '\n'
    return 0
  fi
  printf '%s\n' "${LAUNCHD_STAGING_DIR:-}" \
    "${CLAUDE_HOME:-$HOME/.claude}/Library/LaunchAgents.staging" \
    "$HOME/Library/LaunchAgents"
}

# Lanes currently BOOTSTRAPPED under $LABEL_PREFIX. This is the inverse of the
# label the loop builds (`${LABEL_PREFIX}.${lane}`): every service row in the
# domain listing ends in its label, so keep the rows whose last field is literally
# prefixed and echo the suffix.
loaded_lanes() {
  [ "$launchctl_domain_ok" = "1" ] || return 0
  local line tok
  "$LAUNCHCTL" print "$domain" 2>/dev/null | grep -F "${LABEL_PREFIX}." | while IFS= read -r line; do
    tok="${line##*[[:space:]]}"
    case "$tok" in
      "${LABEL_PREFIX}."?*) printf '%s\n' "${tok#${LABEL_PREFIX}.}" ;;
    esac
  done
}

# Lanes that have a rendered plist but may never have been bootstrapped. This is
# the arm that lets the never-loaded probe see a dead-on-arrival lane at all —
# enumeration of the domain can only ever report lanes that ARE loaded.
staged_lanes() {
  local d f base
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -d "$d" ] || continue
    for f in "$d/${LABEL_PREFIX}."*.plist; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      base="${base%.plist}"
      printf '%s\n' "${base#${LABEL_PREFIX}.}"
    done
  done <<< "$(plist_search_dirs)"
}

# LAST-RESORT FLOOR, not the roster: when the domain is reachable and BOTH
# enumerations come back empty, nothing on the machine can name a lane — fall back
# to the foundation lane pair the installer renders, so a wiped staging dir plus an
# unloaded domain still produces the never-loaded advisory instead of silence.
# Gated on a reachable domain deliberately: on a headless shell "absent" and
# "unobservable" are indistinguishable, and flagging lanes there is a false positive.
FOUNDATION_LANE_FLOOR="writer-reconciler
doc-amender"

derive_lane_roster() {
  local all lane out=""
  all="$( { loaded_lanes; staged_lanes; } | sort -u )"
  if [ -z "$all" ] && [ "$launchctl_domain_ok" = "1" ]; then
    all="$FOUNDATION_LANE_FLOOR"
  fi
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    in_list "$lane" "$UNWATCHED_LANES" && continue
    out="${out}${lane}
"
  done <<< "$all"
  printf '%s' "$out"
}

# --- lane type (read from the plist launchctl already handed us) --------------

# First `path = <plist>` line of a `launchctl print <domain>/<label>` record. The
# record also carries `stdout path =` / `stderr path =` lines, so the match is
# anchored to the START of the trimmed line, not a substring.
lane_plist_from_probe() {
  local line t
  while IFS= read -r line; do
    t="$(trim_ws "$line")"
    case "$t" in
      "path = "?*) printf '%s' "${t#path = }"; return 0 ;;
    esac
  done <<< "$1"
  return 1
}

# Plist text, comment-free where possible. plutil -convert normalizes a binary
# plist AND drops XML comments; the raw read is the degrade path when plutil is
# absent. Dropping comments matters: the shipped templates DISCUSS StartInterval in
# their comment prose ("WatchPaths-only (no StartInterval)"), so trigger detection
# below matches the <key> element form, never the bare word.
plist_text() {
  [ -r "$1" ] || return 1
  if command -v plutil >/dev/null 2>&1; then
    plutil -convert xml1 -o - "$1" 2>/dev/null && return 0
  fi
  cat "$1" 2>/dev/null
}

# interval | watchpaths | unknown
lane_trigger_shape() {
  case "$1" in
    *"<key>StartInterval</key>"*|*"<key>StartCalendarInterval</key>"*)
      printf 'interval'; return 0 ;;
  esac
  case "$1" in
    *"<key>WatchPaths</key>"*) printf 'watchpaths'; return 0 ;;
  esac
  printf 'unknown'
}

# The <string> entries of the plist's WatchPaths array, one per line.
plist_watchpaths() {
  local line v in_wp=0
  while IFS= read -r line; do
    if [ "$in_wp" = "0" ]; then
      case "$line" in *"<key>WatchPaths</key>"*) in_wp=1 ;; esac
      continue
    fi
    case "$line" in
      *"</array>"*) in_wp=0 ;;
      *"<string>"*)
        v="${line#*<string>}"; v="${v%%</string>*}"
        [ -n "$v" ] && printf '%s\n' "$v" ;;
    esac
  done <<< "$1"
}

# Newest mtime across a lane's watched paths. Empty when none is readable.
newest_watch_mtime() {
  local p m best=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$p" ] || continue
    m=$(file_mtime "$p")
    [ "$m" -gt 0 ] 2>/dev/null || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best="$m"; fi
  done <<< "$1"
  printf '%s' "$best"
}

# --- assessment --------------------------------------------------------------

now_epoch=$(date +%s)
degraded=""
roster="$(derive_lane_roster)"

while IFS= read -r lane; do
  [ -n "$lane" ] || continue
  label="${LABEL_PREFIX}.${lane}"

  # (1) never-loaded (dead-on-arrival): the label is not in the GUI domain. The
  # probe output is CAPTURED, not discarded — the lane-type branch reads the
  # `path = <plist>` line out of this same record.
  probe_out=""; probe_ok=0
  if [ "$launchctl_domain_ok" = "1" ]; then
    if probe_out="$("$LAUNCHCTL" print "$domain/$label" 2>/dev/null)"; then
      probe_ok=1
    fi
    if [ "$probe_ok" != "1" ]; then
      degraded="${degraded}
- ${lane}: lane not loaded (${label} is not bootstrapped in ${domain}; run the SessionStart bootstrap or render-launchd.sh ${lane})."
      continue
    fi
  fi

  # (2) staleness: read the wrapper's true activity signal. LOG_DIR may not exist
  # yet on a lane that has never fired — that is benign (nothing to flag).
  [ -d "$LOG_DIR" ] || continue
  mtime="$(newest_activity_mtime "$lane")"
  [ -n "$mtime" ] || continue    # loaded but no activity yet -> benign

  # (3) lane type decides WHICH staleness question is even meaningful. When the
  # trigger shape cannot be read (headless shell, unreadable plist) fall back to
  # the elapsed-time heuristic — the same answer as before, never a new silence.
  shape="unknown"
  watchpaths=""
  if [ "$probe_ok" = "1" ]; then
    plist_path="$(lane_plist_from_probe "$probe_out" || true)"
    if [ -n "$plist_path" ]; then
      ptext="$(plist_text "$plist_path" || true)"
      if [ -n "$ptext" ]; then
        shape="$(lane_trigger_shape "$ptext")"
        [ "$shape" = "watchpaths" ] && watchpaths="$(plist_watchpaths "$ptext")"
      fi
    fi
  fi

  if [ "$shape" = "watchpaths" ]; then
    # Event-driven lane: elapsed time since the last fire measures how long the
    # WATCHED PATH has been quiet, not lane health. The only real signal is an
    # unserviced event — a watched path modified AFTER the last fire.
    # Known residual: a watched dir whose mtime moves for a reason other than an
    # inbound event (e.g. a sibling lane draining it) can produce one advisory.
    # That is a bounded over-report, not the unbounded false-stale this replaces.
    watch_m="$(newest_watch_mtime "$watchpaths")"
    if [ -n "$watch_m" ] && [ "$watch_m" -gt "$mtime" ] 2>/dev/null; then
      gap=$(( watch_m - mtime ))
      if [ "$gap" -ge 3600 ]; then gap_h="$(( gap / 3600 ))h"; else gap_h="${gap}s"; fi
      degraded="${degraded}
- ${lane}: watched path changed ${gap_h} after the last fire (event-driven lane; a trigger arrived and no fire followed)."
    fi
    continue
  fi

  # Interval (or undetermined) lane: elapsed time since the last fire is a valid
  # liveness proxy, because the schedule guarantees a cadence.
  threshold="$(lane_threshold "$lane")"
  age=$(( now_epoch - mtime ))
  if [ "$age" -gt "$threshold" ]; then
    hours=$(( age / 3600 ))
    degraded="${degraded}
- ${lane}: last activity ${hours}h ago (stale; lane may not be firing)."
  fi
done <<< "$roster"

# Healthy -> silent clean pass.
[ -z "$degraded" ] && exit 0

banner="[Cron health] One or more background lanes look degraded:${degraded}
Check launchctl status + ${LOG_DIR}/<lane>-stderr.log."

if command -v format_output_allow >/dev/null 2>&1; then
  format_output_allow "SessionStart" "$banner" || true
else
  printf '%s\n' "$banner" >&2
fi

exit 0
