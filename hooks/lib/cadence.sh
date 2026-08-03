# hooks/lib/cadence.sh — sourceable cadence-window gate for the librarian
# schedulable roster. Source this file — do not execute it:
#
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/cadence.sh"
#
# The librarian capabilities that declare a cron_block cadence (daily | weekly |
# monday) in skills/librarian/capability-registry.json have no background
# scheduler on an adopter install — there is no launchd cron lane behind them.
# Instead the detached session-close consults sweep_due() once per capability
# whenever the operator ends a session, and sweep_due() decides — from a durable
# last-run ledger and a rolling window — whether enough wall-clock has elapsed to
# fire the capability again. This is the real deterministic trigger the cron_block
# roster previously lacked.
#
# --- sweep_due <capability> --------------------------------------------------
#   Resolves the capability's cron_block cadence from the registry, maps it to a
#   rolling window, consults the durable ledger at
#   $CLAUDE_STATE_ROOT/cadence/<capability>.last, and returns:
#     FIRE (rc 0) — no ledger (cold start) OR the window has elapsed. sweep_due
#                   STAMPS the ledger with the current epoch before returning, so
#                   an immediate second call inside the window skips. Cold start
#                   fires every due capability exactly once, then the window
#                   governs — the correct adopter cadence.
#     SKIP (rc 1) — the window has not elapsed, OR the capability is a
#                   DORMANT-until-opt-in adopter check that has not been opted in.
#     rc 2        — the capability declares no schedulable cron_block, or a
#                   dependency (jq / registry) is unavailable (not our concern).
#   The window map: daily -> 86400s, weekly -> 604800s, monday -> 168h (== 604800s)
#   rolling. A detached close cannot align to a wall-clock Monday, so a 7-day
#   rolling window preserves the weekly-Monday cadence faithfully.
#
# --- DORMANT-until-opt-in ----------------------------------------------------
#   Two adopter checks stay dormant until the operator opts in via a durable
#   user-owned key in user-manifest.json behavioral.hook_preferences (read with
#   `jq // "unset"`; tri-state absent/"unset"/"declined" = dormant):
#     - writers-health-audit: dormant unless writers_health_check == "enabled"
#       AND at least one vault writer is registered (a non-underscore .md under
#       $VAULT_ROOT/Vault Writers/). The propose-and-confirm at first-writer
#       registration (skills/govern/modes/writer.sh mode_commit) sets the key.
#     - governance-parity-audit: dormant unless governance_parity_audit ==
#       "enabled". Its governance-pillar inputs are unsatisfiable on an adopter
#       install, so an unconditional weekly fire is incoherent. Manual opt-in —
#       no auto-propose event; the adopter sets the key by hand.
#
# --- cadence_stamp <capability> ----------------------------------------------
#   Public helper: (re)stamp the ledger with the current epoch. sweep_due() stamps
#   on FIRE; a caller that runs the capability may re-stamp to completion time so
#   the window anchors on completion rather than dispatch.
#
# --- cadence_roster ----------------------------------------------------------
#   Prints "<capability>\t<cron_block>" for every schedulable capability in the
#   LIVE registry (daily | weekly | monday), LC_ALL=C-sorted. The caller enumerates
#   this roster and calls sweep_due() per capability — the roster is registry-driven,
#   never a hardcoded list, so every current and future cron_block declaration is
#   covered without editing this library.
#
# Bash 3.2 clean (R-23): no associative arrays, no bash-4 builtins.
#
# Test seams (fixtures only; production resolves the installed layout):
#   CADENCE_REGISTRY   capability-registry.json (default: the installed roster)
#   CLAUDE_STATE_ROOT  ledger root (paths.sh-resolved; fixtures isolate it)
#   USER_MANIFEST_PATH activation-key source
#   VAULT_ROOT         vault root (writer-count source)

# Resolve paths.sh for CLAUDE_STATE_ROOT / VAULT_ROOT / USER_MANIFEST defaults
# without clobbering caller/test env (paths.sh guards every export on [ -z ]).
_cadence_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _cadence_lib_dir=""
if [ -n "$_cadence_lib_dir" ] && [ -r "$_cadence_lib_dir/paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$_cadence_lib_dir/paths.sh" 2>/dev/null || true
fi

# --- registry resolution: env override > installed layout > repo-root fallback ---
_cadence_registry() {
  if [ -n "${CADENCE_REGISTRY:-}" ] && [ -f "$CADENCE_REGISTRY" ]; then
    printf '%s' "$CADENCE_REGISTRY"; return 0
  fi
  local ch="${CLAUDE_HOME:-$HOME/.claude}" repo cand
  repo="${_cadence_lib_dir%/hooks/lib}"
  for cand in "$ch/skills/librarian/capability-registry.json" \
              "$repo/skills/librarian/capability-registry.json"; do
    [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

# --- cadence -> rolling-window seconds --------------------------------------
_cadence_window_secs() {
  case "$1" in
    daily)  printf '86400' ;;
    weekly) printf '604800' ;;
    monday) printf '604800' ;;   # 168h rolling (detached-close approximation of weekly-Monday)
    *)      return 1 ;;
  esac
}

# --- ledger dir (durable under the paths.sh-resolved state root) ------------
_cadence_ledger_dir() {
  local root="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}"
  printf '%s/cadence' "$root"
}

# --- capability-name hygiene (avoid path traversal into the ledger dir) ------
_cadence_valid_cap() {
  case "$1" in
    ''|*[!a-z0-9-]*|[!a-z]*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- activation-key reader (tri-state; jq // "unset") -----------------------
_cadence_activation() {  # $1 = hook_preferences key name
  local um val
  um="${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
  val="unset"
  if command -v jq >/dev/null 2>&1 && [ -f "$um" ]; then
    val="$(jq -r --arg k "$1" '.behavioral.hook_preferences[$k] // "unset"' "$um" 2>/dev/null || echo unset)"
    [ -n "$val" ] && [ "$val" != "null" ] || val="unset"
  fi
  printf '%s' "$val"
}

# --- writer count (dormant-until >=1 registered vault writer) ----------------
_cadence_writer_count() {
  local n=0 w
  if [ -n "${VAULT_ROOT:-}" ] && [ -d "$VAULT_ROOT/Vault Writers" ]; then
    for w in "$VAULT_ROOT/Vault Writers"/*.md; do
      [ -f "$w" ] || continue
      case "$(basename "$w")" in _*) continue ;; esac
      n=$((n + 1))
    done
  fi
  printf '%s' "$n"
}

# --- dormancy gate: rc 0 = DORMANT (never fires), rc 1 = active (may fire) ----
_cadence_dormant() {  # $1 = capability
  case "$1" in
    writers-health-audit)
      if [ "$(_cadence_activation writers_health_check)" = "enabled" ] \
         && [ "$(_cadence_writer_count)" -ge 1 ]; then
        return 1   # active
      fi
      return 0     # dormant
      ;;
    governance-parity-audit)
      if [ "$(_cadence_activation governance_parity_audit)" = "enabled" ]; then
        return 1   # active
      fi
      return 0     # dormant
      ;;
    *)
      return 1     # not a dormant-until-opt-in cap: active
      ;;
  esac
}

# cadence_stamp <capability> — record the current epoch as the last-fire time.
cadence_stamp() {
  local cap="$1" dir
  _cadence_valid_cap "$cap" || return 2
  dir="$(_cadence_ledger_dir)"
  mkdir -p "$dir" 2>/dev/null || return 2
  date +%s > "$dir/$cap.last" 2>/dev/null || return 2
  return 0
}

# cadence_roster — print "<capability>\t<cron_block>" for the LIVE schedulable roster.
cadence_roster() {
  local reg
  reg="$(_cadence_registry)" || return 2
  command -v jq >/dev/null 2>&1 || return 2
  jq -r '.capabilities | to_entries[]
          | select(.value.cron_block=="daily" or .value.cron_block=="weekly" or .value.cron_block=="monday")
          | "\(.key)\t\(.value.cron_block)"' "$reg" 2>/dev/null | LC_ALL=C sort
}

# sweep_due <capability> — rc 0 FIRE (+ stamp), rc 1 SKIP, rc 2 not-schedulable.
sweep_due() {
  local cap="$1" reg block window ledger last now age
  _cadence_valid_cap "$cap" || { printf 'cadence: invalid capability name: %s\n' "$cap" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { printf 'cadence: jq required\n' >&2; return 2; }
  reg="$(_cadence_registry)" || { printf 'cadence: registry not found for %s\n' "$cap" >&2; return 2; }

  block="$(jq -r --arg c "$cap" '.capabilities[$c].cron_block // ""' "$reg" 2>/dev/null)"
  window="$(_cadence_window_secs "$block")" || {
    printf 'cadence: %s has no schedulable cron_block (block=%s)\n' "$cap" "${block:-none}" >&2
    return 2
  }

  # DORMANT-until-opt-in gate (ported from the retired registry plan-printer).
  if _cadence_dormant "$cap"; then
    printf 'cadence: SKIP %s (%s) dormant-until-opt-in\n' "$cap" "$block" >&2
    return 1
  fi

  ledger="$(_cadence_ledger_dir)/$cap.last"
  now="$(date +%s)"
  if [ -r "$ledger" ]; then
    last="$(cat "$ledger" 2>/dev/null)"
    case "$last" in
      ''|*[!0-9]*) last="" ;;   # unreadable / non-integer -> treat as cold start
    esac
    if [ -n "$last" ]; then
      age=$((now - last))
      if [ "$age" -lt "$window" ]; then
        printf 'cadence: SKIP %s (%s) in-window age=%ss < %ss\n' "$cap" "$block" "$age" "$window" >&2
        return 1
      fi
    fi
  fi

  # FIRE: stamp before returning so an immediate second call inside the window SKIPs.
  cadence_stamp "$cap" || { printf 'cadence: FIRE %s (%s) but ledger stamp failed\n' "$cap" "$block" >&2; return 0; }
  printf 'cadence: FIRE %s (%s)\n' "$cap" "$block" >&2
  return 0
}
