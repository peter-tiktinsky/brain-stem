# orchestrator/lib/tripwire.sh — single choke-point for tripwire writes.
# Source this file — do not execute it.
#
#   source "${CLAUDE_HOME:-$HOME/.claude}/lib/paths.sh"          # sets $HOOKS_STATE
#   source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/tripwire.sh"
#   tripwire_fire "<surface>" "<reason>" [<cutoff-seconds>]
#
# Writes a tab-separated ISO-prefixed line to $HOOKS_STATE/tripwire.log
# every time a sanctioned-fire decision lands. The single line shape is:
#
#   <date -Iseconds>\t<surface>\t<reason>
#
# Consumers use cutoff_iso string-compare against the ISO prefix to
# detect fresh fires WITHOUT epoch math on every line scan:
#
#   # reader pattern (inline-documented)
#   cutoff_iso=$(date -j -r $(($(date +%s) - 3600)) -Iseconds)
#   awk -F'\t' -v c="$cutoff_iso" '$1 > c' "$HOOKS_STATE/tripwire.log"
#
# ISO 8601 strings produced by `date -Iseconds` are lexicographically
# sortable as long as every entry uses the same format — which is
# guaranteed because every fire goes through this helper. Mixing
# formats (e.g. `+0000` vs `+00:00`) breaks string-compare; the helper
# is the gate that enforces format consistency.
#
# R-41 generalized — tripwires fire on unexpected CONTENTS, not on
# path existence. Callers decide
# WHEN a fire is appropriate (e.g. "denylisted path appeared in plans
# tree", "stale lockfile contents observed"); this helper writes the
# line. The caller's gate IS the contents-not-existence check; this
# helper does not second-guess it.
#
# Optional [<cutoff-seconds>] argument enables write-side dedup:
# if a prior entry for the same `<surface>` exists within the past
# `cutoff` seconds, this fire is suppressed (no log line written).
# Used to avoid log spam when the same condition keeps tripping inside
# a single watchdog cycle. Returns 0 either way — the helper is a
# success-on-either-branch primitive, not a flow-control gate.
#
# Bash 3.2 clean (R-23): no associative arrays, no mapfile, no [[ =~ ]]
# in production paths, no parameter-expansion case conversion.

# tripwire_fire <surface> <reason> [<cutoff-seconds>]
#
# Writes one TSV line to $HOOKS_STATE/tripwire.log. Returns 0 on success
# (either wrote or deduped). Returns 2 on missing required args or unset
# $HOOKS_STATE.
tripwire_fire() {
  local surface="$1"
  local reason="$2"
  local cutoff_seconds="${3:-}"

  if [ -z "$surface" ] || [ -z "$reason" ]; then
    echo "tripwire_fire: missing required args (surface, reason)" >&2
    return 2
  fi
  if [ -z "${HOOKS_STATE:-}" ]; then
    echo "tripwire_fire: \$HOOKS_STATE unset (source lib/paths.sh first)" >&2
    return 2
  fi

  local log_file="$HOOKS_STATE/tripwire.log"
  mkdir -p "$HOOKS_STATE" 2>/dev/null || true

  # Dedup branch — only when cutoff-seconds is provided AND is a positive
  # integer. Reads the existing log; if any prior fire for this surface
  # has an ISO prefix lexicographically greater than the cutoff_iso, skip
  # the write. The string-compare avoids per-line epoch math.
  if [ -n "$cutoff_seconds" ]; then
    case "$cutoff_seconds" in
      ''|*[!0-9]*)
        echo "tripwire_fire: cutoff-seconds must be a positive integer, got [$cutoff_seconds]" >&2
        return 2
        ;;
    esac
    if [ -r "$log_file" ]; then
      local cutoff_epoch
      cutoff_epoch=$(($(date +%s) - cutoff_seconds))
      local cutoff_iso
      cutoff_iso=$(date -j -r "$cutoff_epoch" -Iseconds 2>/dev/null)
      if [ -n "$cutoff_iso" ]; then
        # awk: tab-separated; field 1 = ISO timestamp, field 2 = surface.
        # If any prior fire matches surface AND its ISO > cutoff_iso, skip.
        local recent
        recent=$(awk -F'\t' -v s="$surface" -v c="$cutoff_iso" \
          '$2 == s && $1 > c { print; exit }' "$log_file" 2>/dev/null)
        if [ -n "$recent" ]; then
          return 0
        fi
      fi
    fi
  fi

  local iso
  iso=$(date -Iseconds)
  printf '%s\t%s\t%s\n' "$iso" "$surface" "$reason" >> "$log_file"
}
