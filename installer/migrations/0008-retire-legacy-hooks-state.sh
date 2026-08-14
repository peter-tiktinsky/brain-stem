#!/bin/bash
# migration: 0008-retire-legacy-hooks-state
# min_from: v0.0.0
# applies_at: v1.13.1
#
# Retire the legacy $CLAUDE_HOME/hooks/state/ empty-dir accretion on an existing adopter
# install. install.sh Step 1 stopped minting the dir at v1.13.1 (its target_dirs roster
# dropped hooks/state), and runtime state resolved to the XDG state tier
# ($CLAUDE_STATE_ROOT/hooks-state, hooks/lib/paths.sh, "NOT $CLAUDE_HOME") long before —
# so on an upgraded install the legacy dir survives only as write-dead residue.
# deliberately scoped this dir OUT of retirement migration 0007 (0007:37-38 "NEVER touches
# ... the legacy ~/.claude/hooks/state/ tree") because install.sh would re-create it and
# the migration/back-compat READ consumers still tolerate it; this migration is the
# standing carve-out closer.
#
# GUARDED remove-if-empty: rmdir $CLAUDE_HOME/hooks/state ONLY when it exists AND is empty
# (find -mindepth 1 -print -quit yields nothing). A dir still holding unmigrated files that
# the READ consumers tolerate (0002 session-registry default path; relocate-state.sh
# reconciler; the waiver-audit / pointer-currency file-fallbacks) is PRESERVED untouched —
# this migration NEVER removes adopter bytes. Absent -> no-op. A fresh v1.13.1 install (the
# dir is never created) is a full no-op.
#
# CONVERGENT + IDEMPOTENT + RE-ARMABLE. Idempotent: a second run finds the dir already gone
# (or still non-empty) and changes nothing. Re-armable is the part that is NOT free, and the
# earlier wording of this header claimed convergence it did not deliver: the PRESERVE branch
# is a DEFERRAL, not a completion, and while it exited the success code the runner recorded
# this migration as applied on the strength of that exit — after which the applied-ids
# set-difference skipped it forever, so an adopter who emptied the directory later never got
# the cleanup. The preserve branch therefore exits the runner-advertised DEFERRAL code
# (MIGRATION_DEFER_RC) instead: the runner maps it to not-applied, this id stays out of
# migrations_applied[], and the cleanup is re-evaluated on every later --apply until the dir
# is genuinely empty (or gone). Run STANDALONE there is no runner and no advertised code, so
# the branch falls back to exit 0 and the standalone "a tolerated precondition exits 0"
# contract is unchanged. See run-migrations.sh, "THE 'RAN, BUT DEFERRED' PROTOCOL".
#
# Root resolution: CLAUDE_HOME is passed by run-migrations.sh (its mutation target);
# defaults to $HOME/.claude standalone. This migration touches ONLY $CLAUDE_HOME/hooks/state
# — never the plans corpus, never the XDG HOOKS_STATE tier, never any file.
#
# bash-3.2 clean; set -u.
set -u

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
case "$CLAUDE_HOME_RES" in */) CLAUDE_HOME_RES="${CLAUDE_HOME_RES%/}" ;; esac
LEGACY_DIR="$CLAUDE_HOME_RES/hooks/state"

# Absent -> no-op (idempotent; a fresh v1.13.1 install never mints it).
if [ ! -d "$LEGACY_DIR" ]; then
  printf '0008: legacy %s absent — no-op (fresh install never mints it)\n' "$LEGACY_DIR" >&2
  exit 0
fi

# Non-empty -> PRESERVE + DEFER (unmigrated files the 0002/relocate read consumers still
# tolerate). find -mindepth 1 -print -quit prints the first entry (incl. dotfiles) and stops;
# empty output => the dir is empty. Pure command substitution (bash-3.2 clean; no process sub).
#
# This branch is a DEFERRAL, not a completion — the cleanup is still owed once the directory
# empties. Exit the runner-advertised deferral code so this id is NOT recorded as applied and
# the migration stays armed; fall back to 0 when no runner advertised one (standalone audit
# run), which keeps the standalone tolerated-precondition-exits-0 contract intact.
if [ -n "$(find "$LEGACY_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  printf '0008: legacy %s is NON-empty — PRESERVED (holds files the 0002/relocate read consumers still tolerate; never removed); cleanup DEFERRED, not complete\n' "$LEGACY_DIR" >&2
  exit "${MIGRATION_DEFER_RC:-0}"
fi

# Empty -> guarded rmdir (write-dead residue; safe to remove).
if rmdir "$LEGACY_DIR" 2>/dev/null; then
  printf '0008: removed empty legacy %s (write-dead residue; runtime state lives at the XDG hooks-state tier)\n' "$LEGACY_DIR" >&2
  exit 0
fi

# A benign race (a concurrent writer re-populated it between the emptiness check and the
# rmdir) is a PRESERVE, never a failure — re-check and no-op rather than error. It is also
# a DEFERRAL by the same reasoning as the non-empty branch above: the dir is still there and
# the cleanup is still owed, so this must not be recorded as applied either.
printf '0008: rmdir of %s did not succeed (re-populated or non-empty) — PRESERVED (no-op); cleanup DEFERRED, not complete\n' "$LEGACY_DIR" >&2
exit "${MIGRATION_DEFER_RC:-0}"
