# hooks/lib/checkpoint-guard.sh — the single "may I overwrite this checkpoint?"
# decision for every writer of sessions/<sid>/checkpoint.md. Source this file —
# do not execute it.
#
#   source "$SCRIPT_DIR/lib/checkpoint-guard.sh"
#   checkpoint_guarded_write "$CHECKPOINT_FILE" <<EOF
#   ...candidate content...
#   EOF
#
# Two hooks overwrite the per-session checkpoint — prompt-context.sh (the passive
# 35% capture) and pre-compact-checkpoint.sh (mechanical extraction) — and each
# used to re-derive the overwrite question from the file's mtime. Age is not
# value: a rich handoff record becomes MORE valuable as it ages, so an mtime
# predicate releases it exactly when a long session has made it irreplaceable.
# The rule this file owns, for every writer:
#
#   1. PRESERVE a rich checkpoint regardless of age.
#   2. Never write a STUB (no structured header) over a structured block.
#   3. ROTATE to a dated variant before any overwrite that does happen.
#
# Rotation is necessary and insufficient on its own: it makes a loss recoverable,
# not prevented, and the operator still loses the live handoff record mid-session
# while every anchored downstream writer no-ops against the stub left behind.
# Clause 1 is the guard; clause 3 is the safety net under the writes it allows.
#
# Richness is the skills/session-checkpoint/SKILL.md binding invariant, NOT a new
# definition: the "# Session Continuity Block" header plus at least three flat
# scalar lines. Both halves are required — a header with too few populated fields
# is a husk, and flat scalars without the header are not a continuity block.
#
# Bash 3.2 clean (R-23). No paths.sh dependency: callers pass an absolute target.

# The SKILL.md invariant's field floor. Changing it changes the shipped contract.
CHECKPOINT_RICH_MIN_FIELDS=3

# checkpoint_has_block <file> — 0 when the structured header is present.
checkpoint_has_block() {
  [ -f "$1" ] && grep -q "^# Session Continuity Block" "$1" 2>/dev/null
}

# checkpoint_is_rich <file> — 0 when the file carries the SKILL.md invariant.
checkpoint_is_rich() {
  local n
  checkpoint_has_block "$1" || return 1
  # grep -c prints 0 and exits 1 on no match; some platforms pad the count.
  n=$(grep -cE "^[a-z_]+: .+$" "$1" 2>/dev/null) || n=0
  n="${n//[^0-9]/}"
  [ -n "$n" ] || n=0
  [ "$n" -ge "$CHECKPOINT_RICH_MIN_FIELDS" ]
}

# checkpoint_guarded_write <target> — reads the candidate content on STDIN and
# applies the rule above. Staging to a temp file is load-bearing twice over: the
# candidate has to be on disk to be classified (stub vs structured), and
# staging + rename is the atomicity every reader of checkpoint.md relies on.
#   rc 0  = written (any prior non-empty content rotated first)
#   rc 10 = PRESERVED — the existing checkpoint outranks the candidate. A normal
#           outcome, not an error; callers under `set -e` must guard the call.
#   rc 1  = staging or rename failed; the target is left untouched.
checkpoint_guarded_write() {
  local target="$1" dir tmp
  [ -n "$target" ] || return 1
  dir=$(dirname "$target")
  tmp="$target.tmp.$$"
  cat > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }

  if [ -f "$target" ] && [ -s "$target" ]; then
    if checkpoint_is_rich "$target"; then
      rm -f "$tmp" 2>/dev/null
      return 10
    fi
    if checkpoint_has_block "$target" && ! checkpoint_has_block "$tmp"; then
      rm -f "$tmp" 2>/dev/null
      return 10
    fi
    # COPY (not move) then rename, so a failed archive never loses the outgoing
    # content; the checkpoint-YYYYMMDD-HHMMSS.md variant is rotation history.
    cp "$target" "$dir/checkpoint-$(date -u +%Y%m%d-%H%M%S).md" 2>/dev/null || true
  fi

  mv "$tmp" "$target" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}
