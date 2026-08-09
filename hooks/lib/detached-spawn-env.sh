# hooks/lib/detached-spawn-env.sh — re-pin the resolution-critical environment
# into a DETACHED child, BEFORE the fork. Source this file — do not execute it.
#
# SANCTIONED CALL-SITE CONTRACT (copy verbatim; every line of it is load-bearing —
# see NEVER FAILS HARD below for what each one survives):
#
#   _DSE="$SCRIPT_DIR/lib/detached-spawn-env.sh"
#   # shellcheck source=/dev/null
#   if "${BASH:-bash}" -n "$_DSE" 2>/dev/null; then . "$_DSE" 2>/dev/null || true; fi
#   if ! command -v pin_detached_spawn_env >/dev/null 2>&1; then pin_detached_spawn_env() { :; }; fi
#   pin_detached_spawn_env || true               # MUST run BEFORE the fork
#   ( "$CHILD" >/dev/null 2>&1 & ) || true
#
# PLACEMENT CONSTRAINT — the block resolves $SCRIPT_DIR, so it MUST sit BELOW the
# hook's `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` line. Placed above it, every
# clause still "works": the `bash -n` on a bogus path fails, the fail-OPEN fallback
# defines the no-op, the hook exits 0 and still spawns — and the scrub is INERT while
# grepping identically to a working one. That exact mis-placement is reproduced
# RED-first by the arm below, so it is asserted, not merely warned about:
# internal/tests/ac-201-t2-detached-spawn-env-helper.sh asserts the injected block's
# line number is greater than the SCRIPT_DIR assignment's in every wired hook.
#
# WHY THIS EXISTS — and WHICH variable is the proven vector
# A hook that backgrounds a child hands that child its own environment and then
# exits. The child re-resolves its world through hooks/lib/paths.sh, whose every
# entry is a `${VAR:-default}` — so any var the parent did NOT transmit is
# re-minted child-side from the install-convention default, in whatever ambient
# the child happens to wake up in.
#
# MEASURED, NOT ASSUMED. The intuitive suspects — CLAUDE_STATE_ROOT / TMPDIR /
# COORD_DIR / PLANS_DIR — were measured and DISCONFIRMED as the vector: paths.sh
# exports all four, so a child's ${VAR:-default} already takes the VAR branch.
# Do not re-derive that disproven premise. The authority is the measured
# characterization (executable form:
#   internal/tests/ac-201-t1-detached-spawn-env-characterization.sh)
#
#   PROVEN VECTOR (mandatory — omitting either leaves the measured escape open)
#     CLAUDE_HOME   paths.sh's `export CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"`
#                   is the fallback that MINTS the live value in the PARENT and then
#                   exports it to every descendant; nothing upstream ever pins it. A
#                   hook running from a repo/worktree tree therefore spawns a child
#                   pointed at the LIVE INSTALL — reached where session-close.sh sets
#                   CAPS_DIR (from which capability BODIES are executed),
#                   RECONCILE_SESSIONS_SH and _SC_CADENCE_LIB; where registry.sh
#                   sources the resolver itself; and where paths.sh reads
#                   user-manifest.json. Confirmed at 6 of 6 logical spawn points.
#     MEMORY_DIR    memory-consolidation-run.sh re-resolves resolve_memory_dir()
#                   ITSELF (its parent resolves the same value but never exports it)
#                   and then `mkdir -p`s the result — so this one is a WRITE the
#                   parent's resolution never reaches.
#
#   DEFENCE-IN-DEPTH (correct hygiene — NOT the fix, and never to be presented as
#   closing the defect)
#     CLAUDE_STATE_ROOT, COORD_DIR, TMPDIR, PLANS_DIR, PLANS_DIR_DEAD
#                   paths.sh `export`s all of these, and every spawning hook sources
#                   paths.sh before it spawns, so the child's `${VAR:-default}`
#                   already takes the `VAR` branch. The characterization measured all of them
#                   resolving to the SANDBOX at every one of the 6 points. Re-pinning
#                   them makes the transmission EXPLICIT instead of contingent on
#                   paths.sh continuing to export them — which is worth having, and
#                   is not what closes the escape.
#
# THE RULE FOR CLAUDE_HOME — self-anchor, because the parent's own resolution is
# the thing that is wrong
# Re-exporting the value the parent already holds would be INERT: the parent's
# CLAUDE_HOME *is* the escape (paths.sh minted it from $HOME/.claude). So the pin
# resolves CLAUDE_HOME to the tree THIS FILE LIVES IN — <root>/hooks/lib/ -> <root> —
# which is by construction the tree the spawning hook itself was loaded from, since
# every hook sources its libs $SCRIPT_DIR-relative. Precedence:
#
#   CLAUDE_HOME unset                      -> anchor
#   CLAUDE_HOME == anchor                  -> anchor          (no-op; idempotent)
#   CLAUDE_HOME == "$HOME/.claude"         -> anchor          (THE FIX: this is the
#                                             install-convention default paths.sh
#                                             mints when nobody pinned it)
#   CLAUDE_HOME == any other value         -> LEFT ALONE      (a caller pinned a third
#                                             tree deliberately; paths.sh's documented
#                                             "caller-set environment variable wins"
#                                             precedence is preserved)
#
# In a REAL install the anchor and $HOME/.claude are the same path, so the pin is a
# byte-for-byte no-op on the adopter's critical path. It only bites where the hook
# body being executed does NOT live under $HOME/.claude — the repo, a worktree, a
# fixture tree — which is precisely the escape.
#
# ORDERING IS LOAD-BEARING, in two places:
#   1. The pin must run BEFORE the fork. A scrub applied after the child is forked
#      is inert while grepping identically to a working one.
#   2. CLAUDE_HOME is pinned FIRST, and MEMORY_DIR is derived AFTER it. MEMORY_DIR
#      is rooted at $CLAUDE_HOME, so resolving it against the pre-pin value would
#      pin the escape instead of closing it.
# A later `source paths.sh` inside the child does NOT shadow the pin: paths.sh
# honors an already-set value on every one of these vars. That is the same property
# the characterization measured for the defence-in-depth four.
#
# NEVER FAILS HARD — these hooks are on the SessionStart/SessionEnd critical path
# Every branch below is a conditional or is `|| true`-guarded, the function always
# `return 0`s, and NO shell option is set here (a sourced lib that ran `set -e`
# would silently re-arm its caller). memory-consolidation-check.sh runs under
# `set -euo pipefail`, so both -e and -u safety are hard requirements, not manners.
#
# DEGRADE (loud-safe; the drift-sweep.sh merger-resolution posture — resolve, fall
# back, never break). Each clause of the call-site contract answers one measured
# failure, and they are NOT interchangeable:
#   - helper file MISSING or UNREADABLE: `. … 2>/dev/null || true` returns non-zero
#     and is absorbed; the fail-OPEN fallback then defines the no-op so the later
#     call is not an rc=127 that `set -e` turns into a dead SessionEnd.
#   - helper file TRUNCATED / SYNTACTICALLY CORRUPT — the "partial tree" shape, and
#     the one that needs the `bash -n` pre-parse. MEASURED on bash 3.2: a parse error
#     inside a sourced file EXITS the sourcing shell outright; `. bad 2>/dev/null ||
#     true` does NOT save it (the `||` never runs). The pre-parse is therefore the
#     only thing standing between a half-written lib and a SessionEnd hook that dies
#     before it spawns. It costs ~2ms, is skipped on a missing bash, and a failing
#     parse simply means the pin does not load.
#   - helper LOADS but its function MISBEHAVES (non-zero return, unbound command):
#     `pin_detached_spawn_env || true` absorbs it. A bare call under `set -e` would
#     propagate the non-zero and kill the hook.
#   - anchor underivable: CLAUDE_HOME is LEFT AS RESOLVED rather than guessed.
#   - resolve_memory_dir() undefined: the sibling paths.sh in this file's own tree is
#     sourced once as a recovery; if that is unavailable too, MEMORY_DIR is left
#     alone rather than invented.
# The degrade is OBSERVABLE, not silent: $DETACHED_SPAWN_ENV_PINNED is exported into
# the child carrying the anchor that was used, or the literal `degraded-no-anchor`;
# its ABSENCE in the child is the signal that the helper never loaded at all.
#
# IDEMPOTENT + RE-ENTRANT: applying the pin twice equals applying it once (after the
# first application CLAUDE_HOME == anchor, which is the no-op branch), and the
# backstop reaches its spawns through a lockf re-exec'd child that re-sources
# paths.sh and pins again.
#
# STATED RESIDUAL, measured rather than assumed: paths.sh also derives HOOKS_DIR,
# SCHEMAS_DIR, CRON_WRAPPERS, ORCHESTRATION_JSON and CLAUDE_GIT_REPO off CLAUDE_HOME
# and exports them; this helper does NOT re-derive them, because the characterization did not
# implicate them and the scrub is deliberately scoped to the set it did. None of the
# three detached children reads any of them (asserted at runtime by
# internal/tests/ac-201-t2-detached-spawn-env-helper.sh, roster derived from paths.sh
# rather than hardcoded). HOOKS_STATE / SESSION_STATE_ROOT / CLAUDE_LOG_DIR derive
# off CLAUDE_STATE_ROOT, which IS pinned, so they are consistent by construction.
#
# Contains NO backgrounding idiom of its own (subshell `( … & )`, bare trailing `&`,
# nohup, disown, setsid, coproc) — deliberately, so the repo-wide idiom-family sweep
# that asserts "zero un-scrubbed detached spawns in hooks/" never has to special-case
# the scrubber itself.
#
# Bash 3.2 clean (R-23): no associative arrays, no `${var,,}`, no `mapfile`, no
# `declare -A`, no regex capture groups.

# --- self-anchor, captured at SOURCE time ------------------------------------
# <this file>/../.. — hooks/lib -> hooks -> tree root. Captured here rather than
# inside the function so the anchor reflects where the helper was LOADED FROM even
# if a caller later changes directory.
_DSE_TREE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd 2>/dev/null)" \
  || _DSE_TREE_ROOT=""
[ -n "${_DSE_TREE_ROOT:-}" ] || _DSE_TREE_ROOT=""

# detached_spawn_env_anchor — print the tree root this helper anchors to (empty when
# it could not be derived). Read-only accessor so consumers and fixtures can observe
# the anchor without reaching into a private.
detached_spawn_env_anchor() {
  printf '%s' "${_DSE_TREE_ROOT:-}"
  return 0
}

# pin_detached_spawn_env — export the pinned environment into the CURRENT shell so
# the next fork inherits it. Call it in the spawning parent immediately before the
# spawn, or as the first statement inside the spawn subshell; either placement works,
# both are before the fork. Takes no arguments. ALWAYS returns 0.
pin_detached_spawn_env() {
  local _anchor _prev _new _mem

  _anchor="${_DSE_TREE_ROOT:-}"
  _prev="${CLAUDE_HOME:-}"
  _new="$_prev"

  # --- (1) PROVEN VECTOR — CLAUDE_HOME --------------------------------------
  # The `-d "$_anchor/hooks/lib"` check is a self-consistency guard: this file lives
  # at <anchor>/hooks/lib/, so a failing check means the anchor is not a hook tree
  # and must not be pinned.
  if [ -n "$_anchor" ] && [ -d "$_anchor/hooks/lib" ]; then
    if [ -z "$_prev" ] || [ "$_prev" = "$_anchor" ] || [ "$_prev" = "${HOME:-}/.claude" ]; then
      _new="$_anchor"
    fi
  fi
  if [ -n "$_new" ]; then
    CLAUDE_HOME="$_new"
    export CLAUDE_HOME
  fi

  # --- (2) PROVEN VECTOR — MEMORY_DIR ---------------------------------------
  # Order matters: this runs AFTER the CLAUDE_HOME pin. A MEMORY_DIR the caller
  # derived from the PRE-pin CLAUDE_HOME is rebased onto the pinned one (pure string
  # work — no subprocess, so the memory-consolidation-check.sh <100ms budget is
  # untouched on the path where the hook already resolved it). A MEMORY_DIR that is
  # not rooted at the old CLAUDE_HOME was chosen deliberately (env / flat override)
  # and is honored as-is.
  _mem="${MEMORY_DIR:-}"
  if [ -n "$_mem" ] && [ -n "$_prev" ] && [ "$_prev" != "$_new" ]; then
    case "$_mem" in
      "$_prev"/*) _mem="$_new/${_mem#"$_prev"/}" ;;
    esac
  fi
  if [ -z "$_mem" ]; then
    if ! command -v resolve_memory_dir >/dev/null 2>&1; then
      # Recovery, not a normal path: every spawning hook sources paths.sh (directly
      # or via registry.sh) long before it spawns. Source the sibling in this file's
      # OWN tree — after the CLAUDE_HOME pin, so it resolves against the pinned base.
      if [ -n "$_anchor" ] && [ -r "$_anchor/hooks/lib/paths.sh" ]; then
        # shellcheck source=/dev/null
        . "$_anchor/hooks/lib/paths.sh" 2>/dev/null || true
      fi
    fi
    if command -v resolve_memory_dir >/dev/null 2>&1; then
      _mem="$(resolve_memory_dir 2>/dev/null)" || _mem=""
    fi
  fi
  if [ -n "$_mem" ]; then
    MEMORY_DIR="$_mem"
    export MEMORY_DIR
  fi

  # --- (3) DEFENCE-IN-DEPTH -------------------------------------------------
  # Re-pin what the HOOK resolved; never invent a value the hook did not have. An
  # empty var here means paths.sh was never sourced (or, for TMPDIR, that nothing
  # ever set it — paths.sh does not), and inventing one would be a different bug.
  if [ -n "${CLAUDE_STATE_ROOT:-}" ]; then export CLAUDE_STATE_ROOT; fi
  if [ -n "${COORD_DIR:-}" ];         then export COORD_DIR;         fi
  if [ -n "${TMPDIR:-}" ];            then export TMPDIR;            fi
  if [ -n "${PLANS_DIR:-}" ];         then export PLANS_DIR;         fi
  # PLANS_DIR_DEAD is the already-shipped test/CI corpus dead-switch consumed by
  # session-close.sh, and is legitimately EMPTY in production. paths.sh exports it
  # empty; transmit it the same way so the child's `${PLANS_DIR_DEAD:-}` reads
  # exactly what the parent held.
  PLANS_DIR_DEAD="${PLANS_DIR_DEAD:-}"
  export PLANS_DIR_DEAD

  # --- (4) receipt — makes the degrade observable in the CHILD ---------------
  if [ -n "$_anchor" ]; then
    DETACHED_SPAWN_ENV_PINNED="$_anchor"
  else
    DETACHED_SPAWN_ENV_PINNED="degraded-no-anchor"
  fi
  export DETACHED_SPAWN_ENV_PINNED

  return 0
}
