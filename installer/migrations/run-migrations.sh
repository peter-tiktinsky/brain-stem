#!/bin/bash
# installer/migrations/run-migrations.sh —
# (forward-only idempotent migrations runner + migrations_applied[]
#    high-water log)
#
# ============================ WHAT THIS IS ===================================
# The forward-only, idempotent migration runner. install.sh invokes it AFTER
# Step 13.5 (the freshly-copied foundation-manifest.json has parse-validated);
# it iterates the shipped migrations/NNNN-slug.sh files in numeric prefix order
# (Flyway lexical/numeric ordering) and selects each migration by the applied-ids
# SET-DIFFERENCE: a migration runs iff its id is NOT already in the high-water log
# (APPLIED_IDS) AND its `applies_at` header is <= TARGET_VERSION. The strictly-
# above-floor clause (applies_at > INSTALLED_VERSION) is a DIAGNOSTIC only, NOT a
# selection guarantee — a bitten install whose stamp advanced past a migration's
# applies_at must still heal on its next run, so the applied-ids set-difference (not
# the version floor) is the idempotence guarantee. It runs the selected set and on
# each success appends the id to the high-water log. THIS HEADER is the shipped
# selection contract.
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
#   MIG_DEFERRED_OUT   — OPTIONAL path. When set, each DEFERRED id is appended to
#                        it, one per line, so the caller can report pending
#                        cleanups to the operator. Unset -> deferrals are logged
#                        to stderr only.
#
# OUTPUT:
#   stdout — one APPLIED migration id PER LINE, in apply order (the caller folds
#            these into migrations_applied[] for the .installed-state.json stamp).
#            A DEFERRED migration is deliberately NOT on stdout. Diagnostics +
#            WARNs go to stderr only, so stdout stays a clean id list (mirrors
#            install.sh's dry-run-JSON-on-stdout discipline).
#   exit 0 — every selected migration converged, deferred, or was correctly
#            skipped.
#   exit 1 — a migration exited non-zero AND that code was not the deferral code.
#            The caller MUST NOT bump foundation_version (the partial high-water
#            mark is the ids already emitted on stdout before the failure).
#            Up-only; no down-migrations.
#
# ------------------- THE "RAN, BUT DEFERRED" PROTOCOL -------------------------
# A GUARDED conditional migration (remove-if-empty, converge-if-safe) has a third
# outcome that this lane could not express: it ran, it did the RIGHT thing, but it
# could NOT do its job because its precondition was not met. Exiting 0 for that
# case conflates "I completed without error" with "I performed my job": the runner
# emits the id, the caller folds it into migrations_applied[], and the selection
# set-difference below then skips it FOREVER — the cleanup is permanently
# forfeited by its own no-op branch, even after the precondition is later met.
#
# The runner therefore ADVERTISES a deferral code to every migration it invokes,
# via MIGRATION_DEFER_RC. A migration that speaks the protocol exits that code
# from its ran-but-deferred branch; the runner maps it to NOT-APPLIED (id withheld
# from stdout, so the id never enters the high-water log and the migration stays
# armed for the next --apply) and CONTINUES the chain. A deferral is NOT a failure:
# it must never reach the caller's non-zero lane (install.sh exit 41 / the rollback
# envelope), because nothing went wrong and there is nothing to roll back.
#
# The code is ADVERTISED rather than hardcoded into migration bodies because a
# migration is also runnable STANDALONE (adopter audit; each body defaults
# CLAUDE_HOME to $HOME/.claude). With no runner present MIGRATION_DEFER_RC is
# unset, the body falls back to exit 0, and the pre-existing standalone contract —
# a body run against a tolerated precondition exits 0 — is preserved exactly. The
# protocol is additive: a migration that does not speak it behaves as before.
#
# 75 is sysexits.h EX_TEMPFAIL ("temporary failure; the user is invited to retry"),
# which is precisely "ran, but deferred". It is distinct from the caller's own
# migration-failure exit (41) and from the shell's 1/2/126/127/128+N codes.
#
# bash-3.2-safe (R-23): no associative arrays, no mapfile, no process
# substitution in the hot path.
set -u

# The deferral code the runner advertises to every migration it invokes and maps
# back to NOT-APPLIED. See "THE 'RAN, BUT DEFERRED' PROTOCOL" above.
MIG_DEFER_RC=75

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

  local f id min_from applies_at v_lo v_hi v_minfrom mig_rc
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
    v_lo="$(mig_vercmp "$applies_at" "$floor")"   # applies_at vs floor (diagnostic only)
    v_hi="$(mig_vercmp "$applies_at" "$target")"  # applies_at vs target (selection ceiling)
    # selection: id NOT-IN APPLIED_IDS  AND  applies_at <= target. The strictly-above-
    # floor clause is DEMOTED to a diagnostic (below) — a bitten install whose stamp
    # already advanced past applies_at MUST still heal, so the applied-ids set-difference
    # (the high-water skip below), NOT the floor, is the idempotence guarantee.
    if [ "$v_lo" != "a>b" ]; then
      _mig_log "NOTE $id: applies_at=$applies_at <= floor=$floor — at/below floor; selection now defers to the applied-ids set-difference (not the floor)"
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
    # Three outcomes, not two: APPLIED (0) / DEFERRED (MIG_DEFER_RC) / FAILED
    # (anything else). MIGRATION_DEFER_RC advertises the deferral code to the body.
    _mig_log "RUN  $id ($f): applies_at=$applies_at min_from=${min_from:-<none>}"
    MIGRATION_DEFER_RC="$MIG_DEFER_RC" CLAUDE_HOME="${CLAUDE_HOME:-}" bash "$f" >&2
    mig_rc=$?
    if [ "$mig_rc" -eq 0 ]; then
      # applied -> emit the id on stdout (the caller appends it to the log)
      printf '%s\n' "$id"
    elif [ "$mig_rc" -eq "$MIG_DEFER_RC" ]; then
      # ran, but DEFERRED: the migration did the right thing and its precondition
      # was not met. NOT applied -> the id is withheld from stdout, so it never
      # enters migrations_applied[] and the migration stays ARMED for a later
      # --apply. NOT a failure -> the chain continues and the caller's non-zero
      # lane (exit 41 / rollback) is never reached.
      _mig_log "DEFER $id ($f): ran, but its precondition was NOT met — NOT recorded as applied; it stays armed and is re-evaluated on the next --apply."
      if [ -n "${MIG_DEFERRED_OUT:-}" ]; then
        printf '%s\n' "$id" >> "$MIG_DEFERRED_OUT"
      fi
      continue
    else
      _mig_log "FAIL $id ($f) exited non-zero ($mig_rc) — halting the chain (forward-only; no down-migration). foundation_version MUST NOT bump."
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
