#!/bin/bash
# installer/migrations/run-migrations.sh —
# (forward-only idempotent migrations runner + migrations_applied[]
#    high-water log)
#
# ============================ WHAT THIS IS ===================================
# The forward-only, idempotent migration runner. install.sh invokes it AFTER
# Step 13.5 (the freshly-copied foundation-manifest.json has parse-validated);
# it iterates the shipped migrations/NNNN-slug.sh files in numeric prefix order
# (Flyway lexical/numeric ordering), selects those whose `applies_at` header is
# in the half-open range (INSTALLED_VERSION, TARGET_VERSION], skips any whose id
# is already in the high-water log, runs the rest, and on each success appends
# the id to the high-water log.
#
# It ships to $CLAUDE_HOME/migrations/ as a FOUNDATION-REPLACE surface so the
# adopter has the runner locally for audit.
#
# ----------------------------- CONTRACT --------------------------------------
# INPUTS (env):
#   MIGRATIONS_DIR     — directory holding the NNNN-slug.sh migration files
#                        (default: the directory this script lives in).
#   INSTALLED_VERSION  — the detected on-disk floor (e.g. v1.0.2). The legacy /
#                        fresh sentinel "(none)" is normalized to the v0.0.0
#                        floor (run the full chain from 0001; line 120).
#   TARGET_VERSION     — the shipped manifest .version (the ceiling).
#   APPLIED_IDS        — newline-separated ids already in migrations_applied[]
#                        (the high-water log read from .installed-state.json by
#                        the caller). Each is skipped (belt-and-suspenders with
#                        the per-migration structural probe).
#   FLOOR_IS_REAL      — "1" when INSTALLED_VERSION is a real sha-matched stamped
#                        version (so min_from > floor is a meaningful SKIP-WARN);
#                        "0"/absent for the v0.0.0 unknown-floor legacy-adopt path
#                        (every migration must tolerate the oldest/empty
#                        precondition per the authoring contract — never
#                        min_from-skipped in this lane).
#   CLAUDE_HOME        — passed through to each migration (its mutation target).
#
# OUTPUT:
#   stdout — one applied migration id PER LINE, in apply order (the caller folds
#            these into migrations_applied[] for the .installed-state.json stamp).
#            Diagnostics + WARNs go to stderr only, so stdout stays a clean id
#            list (mirrors install.sh's dry-run-JSON-on-stdout discipline).
#   exit 0 — every selected migration converged (or was correctly skipped).
#   exit 1 — a migration exited non-zero. The caller MUST NOT bump
#            foundation_version (the partial high-water mark is the ids already
#            emitted on stdout before the failure). Up-only; no down-migrations.
#
# bash-3.2-safe (R-23): no associative arrays, no mapfile, no process
# substitution in the hot path.
set -u

_mig_log() { printf 'migrations: %s\n' "$1" >&2; }

# --- self-contained vercmp (the adopter audits this script standalone) -------
# Identical semantics to install.sh:vercmp: strip leading 'v',
# compare major.minor.patch numerically with $((10#$seg)) octal-guard coercion
# (matches hooks/spec-context-inject.sh:84) so a zero-padded 08/09 segment never
# trips "value too great for base" under set -u. Prints: equal | a>b | a<b.
mig_vercmp() {
  local a="${1#v}" b="${2#v}" i aseg bseg an bn
  for i in 1 2 3; do
    aseg="$(printf '%s' "$a" | cut -d. -f"$i")"
    bseg="$(printf '%s' "$b" | cut -d. -f"$i")"
    aseg="${aseg%%[!0-9]*}"; bseg="${bseg%%[!0-9]*}"
    [ -n "$aseg" ] || aseg=0
    [ -n "$bseg" ] || bseg=0
    an=$((10#$aseg)); bn=$((10#$bseg))
    if [ "$an" -gt "$bn" ]; then printf 'a>b'; return 0; fi
    if [ "$an" -lt "$bn" ]; then printf 'a<b'; return 0; fi
  done
  printf 'equal'
  return 0
}

# --- read a `# key: value` header field from a migration file ----------------
# Reads only the leading comment block (stops at the first non-comment, non-blank
# line) so a body line that happens to match the pattern can't be misread.
mig_header() { # mig_header <file> <key>
  local file="$1" key="$2" line val
  while IFS= read -r line; do
    case "$line" in
      \#*) ;;                 # comment — inspect it
      '') continue ;;         # blank — still in/leading the header
      *) break ;;             # first real code line — header done
    esac
    case "$line" in
      "# $key:"*)
        val="${line#*: }"
        # strip a trailing inline comment + surrounding whitespace
        val="${val%%#*}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        printf '%s' "$val"
        return 0
        ;;
    esac
  done < "$file"
  return 0
}

mig_id_applied() { # mig_id_applied <id> ; true (rc 0) if id ∈ APPLIED_IDS
  local id="$1"
  [ -n "${APPLIED_IDS:-}" ] || return 1
  printf '%s\n' "$APPLIED_IDS" | grep -qxF "$id"
}

run_migrations() {
  local dir="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  local installed="${INSTALLED_VERSION:-(none)}"
  local target="${TARGET_VERSION:-}"
  local floor_is_real="${FLOOR_IS_REAL:-0}"

  # legacy/fresh sentinel -> v0.0.0 floor (run the full chain from 0001).
  # In this lane min_from is NEVER a skip reason — the floor is unknown, and
  # every migration is authored to tolerate the oldest/empty precondition.
  local floor="$installed"
  if [ "$installed" = "(none)" ]; then
    floor="v0.0.0"
    floor_is_real="0"
  fi

  if [ -z "$target" ]; then
    _mig_log "TARGET_VERSION empty; no migration range to evaluate (no-op)"
    return 0
  fi
  if [ ! -d "$dir" ]; then
    _mig_log "migrations dir absent ($dir); nothing to run (no-op)"
    return 0
  fi

  local f id min_from applies_at v_lo v_hi v_minfrom
  # Numeric/lexical prefix order = plain glob sort (NNNN zero-padded).
  for f in "$dir"/[0-9][0-9][0-9][0-9]-*.sh; do
    [ -e "$f" ] || continue          # no-match glob guard
    [ -f "$f" ] || continue

    id="$(mig_header "$f" "migration")"
    [ -n "$id" ] || id="$(basename "$f" .sh)"
    applies_at="$(mig_header "$f" "applies_at")"
    min_from="$(mig_header "$f" "min_from")"

    # --- selection: applies_at ∈ (floor, target] -----------------------------
    if [ -z "$applies_at" ]; then
      _mig_log "SKIP $id: no applies_at header (cannot place in the version range)"
      continue
    fi
    v_lo="$(mig_vercmp "$applies_at" "$floor")"   # applies_at vs floor
    v_hi="$(mig_vercmp "$applies_at" "$target")"  # applies_at vs target
    # half-open (floor, target]: applies_at must be STRICTLY > floor AND <= target
    if [ "$v_lo" != "a>b" ]; then
      _mig_log "SKIP $id: applies_at=$applies_at <= floor=$floor (already past this version)"
      continue
    fi
    if [ "$v_hi" = "a>b" ]; then
      _mig_log "SKIP $id: applies_at=$applies_at > target=$target (above the upgrade ceiling)"
      continue
    fi

    # --- high-water skip (idempotent re-run) ---------------------------------
    if mig_id_applied "$id"; then
      _mig_log "SKIP $id: already in migrations_applied[] (high-water log)"
      continue
    fi

    # --- min_from gate (honor or SKIP-WARN; advisory correction) -------------
    # Only meaningful on a REAL sha-matched floor. On the v0.0.0 unknown-floor
    # legacy-adopt lane, every migration is authored to tolerate the oldest
    # precondition, so min_from is NOT a skip reason there.
    if [ -n "$min_from" ] && [ "$floor_is_real" = "1" ]; then
      v_minfrom="$(mig_vercmp "$min_from" "$floor")"
      if [ "$v_minfrom" = "a>b" ]; then
        _mig_log "WARN: SKIP $id: min_from=$min_from > detected floor=$floor (precondition not met on a real sha-matched version)"
        continue
      fi
    fi

    # --- run the migration (converge-if-needed; its own structural probe) ----
    _mig_log "RUN  $id ($f): applies_at=$applies_at min_from=${min_from:-<none>}"
    if CLAUDE_HOME="${CLAUDE_HOME:-}" bash "$f" >&2; then
      # success -> emit the id on stdout (the caller appends it to the log)
      printf '%s\n' "$id"
    else
      _mig_log "FAIL $id ($f) exited non-zero — halting the chain (forward-only; no down-migration). foundation_version MUST NOT bump."
      return 1
    fi
  done
  return 0
}

# Allow `source`-ing for unit testing without auto-running, but auto-run when
# executed directly (the install.sh invocation path).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  run_migrations
fi
