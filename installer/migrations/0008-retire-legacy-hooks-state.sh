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
# this migration NEVER removes adopter bytes. Absent -> no-op. Convergent + idempotent: a
# second run finds the dir already gone (or still non-empty) and changes nothing. A fresh
# v1.13.1 install (the dir is never created) is a full no-op.
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

# Non-empty -> PRESERVE (unmigrated files the 0002/relocate read consumers still tolerate).
# find -mindepth 1 -print -quit prints the first entry (incl. dotfiles) and stops; empty
# output => the dir is empty. Pure command substitution (bash-3.2 clean; no process sub).
if [ -n "$(find "$LEGACY_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  printf '0008: legacy %s is NON-empty — PRESERVED (holds files the 0002/relocate read consumers still tolerate; never removed)\n' "$LEGACY_DIR" >&2
  exit 0
fi

# Empty -> guarded rmdir (write-dead residue; safe to remove).
if rmdir "$LEGACY_DIR" 2>/dev/null; then
  printf '0008: removed empty legacy %s (write-dead residue; runtime state lives at the XDG hooks-state tier)\n' "$LEGACY_DIR" >&2
else
  # A benign race (a concurrent writer re-populated it between the emptiness check and the
  # rmdir) is a PRESERVE, never a failure — re-check and no-op rather than error.
  printf '0008: rmdir of %s did not succeed (re-populated or non-empty) — PRESERVED (no-op)\n' "$LEGACY_DIR" >&2
fi
exit 0
