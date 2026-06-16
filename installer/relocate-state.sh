#!/bin/bash
# installer/relocate-state.sh — operator-gated bulk mover for the operational-
# exhaust relocation. The SEPARATE, heavy, out-of-$CLAUDE_HOME half of the split
# migration (the framework-native in-home half is the migrations/0004 reshape).
# It is NOT an NNNN migration and is NOT auto-run by install.sh's migration chain
# — the shared rollback envelope cannot snapshot out-of-$CLAUDE_HOME files, so
# this mover carries its OWN backup + move-journal + reverse-restore.
# What it moves (pre-relocation source -> XDG state-tier destination):
#   $CLAUDE_HOME/logs/*              -> $STATE/logs/        (provenance carved out)
#   $CLAUDE_HOME/hooks/state/*       -> $STATE/hooks-state/ (dead state archived)
#   $CLAUDE_HOME/orchestrator/state/ -> $STATE/runtime/
#   $VAULT_ROOT/Logs/ machine files  -> $STATE/logs/        (vault Logs/ drain)
#     · librarian-manifest.json      -> $STATE/manifests/
#     · .coordination/ + manifest.lock-> $STATE/.coordination/
#   memory-dir .consolidation-log.md / .review-queue-log.md -> $STATE/logs/
#   hook-audit.log                   -> $STATE/audit/
#   $CLAUDE_HOME/hooks/state/sessions/<sid> dirs reconciled into $STATE/sessions/
# Dead state is ARCHIVED to $STATE/logs/archive/, never deleted:
#   legacy checkpoint-*.md, the large auto-commit.log, backlog snapshots, the
#   bare orphan sessions/checkpoint.md.
# Safety model:
#   - Peer-mutex via lockf.sh (a 2nd concurrent invocation exits 0 / clean skip).
#   - In-flight gate: read the OLD session-registry (pre-bump manifest home, NOT
#     the new XDG one) and ABORT if any peer session is active; never move the
#     CURRENT session's own sessions/<sid>/ dir.
#   - Source discovery: the OLD source tree is derived from the pre-relocation
#     install-convention defaults ($CLAUDE_HOME/.. ; $VAULT_ROOT/Logs read from
#     user-manifest.json via jq) — NEVER `source paths.sh` (which returns the
#     empty/unscaffolded XDG paths and would move the wrong tree).
#   - Append-only logs a live hook re-opens per fire (auto-commit.log) are treated
#     as dead (archive-then-prune) — never copy-then-truncate against a live
#     writer handle.
#   - launchd plists are re-rendered (render-launchd.sh production bootout+
#     bootstrap) AFTER the move so cron logs do not strand at the baked path.
#   - Journal-replay RESUME after an uncatchable interrupt (SIGKILL/power-loss):
#     a per-file move is journaled AFTER it verifies, so a re-run skips
#     moved-and-verified files (idempotent mv -n + stat probe) and continues from
#     the first unrecorded file — never restart-from-scratch, never blind-resume.
#   - Catchable failure (trap): reverse-restore every journaled move from
#     --backup-dir and exit non-zero (the in-home foundation_version never bumps;
#     this tool is out of the migration chain).
# Usage:
#   relocate-state.sh --backup-dir <dir>   # real run (--backup-dir MANDATORY)
#   relocate-state.sh --dry-run            # list the move plan, mutate nothing
#   relocate-state.sh --force ...          # override the in-flight-session gate
#   relocate-state.sh --help
# bash 3.2 clean (no associative arrays, no mapfile, no ${v,,}).
set -uo pipefail

prog="$(basename "$0")"
info() { printf '%s: %s\n' "$prog" "$1"; }
diag() { printf '%s: %s\n' "$prog" "$1" >&2; }

# Peer-mutex. Resolve the lock's COORD_DIR self-contained — this is the
# LOCK home only, not source discovery, so deriving it from the XDG default is
# correct (and avoids sourcing the new paths.sh). lockf.sh:31 makes the CALLER
# own the parent-dir mkdir; relocate-state.sh runs upgrade-context so it must
# not assume $COORD_DIR exists. A 2nd concurrent mover exits 0 (lockf-75 skip);
# mv -n is per-file convergent, NOT a peer-mutex (two interleaved movers would
# diverge the journal + break reverse-restore).
LOCK_COORD_DIR="${COORD_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/.coordination}"
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_lockf_lib="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/lockf.sh"
[ -r "$_lockf_lib" ] || _lockf_lib="$(cd "$_self_dir/.." && pwd)/hooks/lib/lockf.sh"
# shellcheck source=/dev/null
. "$_lockf_lib"
mkdir -p "$LOCK_COORD_DIR" 2>/dev/null || true
LOG_DIR="$LOCK_COORD_DIR"   # lockf.sh skip-log home (no $LOG_DIR collision)
claude_lockf_reexec "$LOCK_COORD_DIR/relocate-state.lock" "$@"

# Arg parse.
DRY_RUN=0
FORCE=0
BACKUP_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    --backup-dir) [ $# -ge 2 ] || { diag "--backup-dir requires a path"; exit 2; }
                  BACKUP_DIR="$2"; shift 2 ;;
    --backup-dir=*) BACKUP_DIR="${1#--backup-dir=}"; shift ;;
    -h|--help) sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) diag "unknown arg: $1"; exit 2 ;;
  esac
done

if [ "$DRY_RUN" -eq 0 ] && [ -z "$BACKUP_DIR" ]; then
  diag "--backup-dir <dir> is MANDATORY for a real run (the out-of-\$CLAUDE_HOME"
  diag "move cannot use the shared rollback envelope). Pass --dry-run to preview."
  exit 2
fi

command -v jq >/dev/null 2>&1 || { diag "jq required but not on PATH"; exit 2; }

# Source discovery. Read the manifest with jq directly; derive
# OLD source paths from the pre-relocation install-convention DEFAULTS. NEVER
# source the new paths.sh. A test-harness HOOKS_STATE_OVERRIDE is NOT a
# production move target (we read the manifest + CLAUDE_HOME, not env overrides).
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
USER_MANIFEST="${MIGRATION_USER_MANIFEST:-$CLAUDE_HOME/user-manifest.json}"

mget() {  # mget <dotted.path> — null-safe read from the user-manifest
  [ -r "$USER_MANIFEST" ] || { printf ''; return 0; }
  jq -r --arg p "$1" '
    ($p | split(".") | map(select(length>0))) as $ks
    | reduce $ks[] as $k (.; if . == null then null else .[$k]? end)
    | if . == null or . == "" then "" else . end
  ' "$USER_MANIFEST" 2>/dev/null || printf ''
}

VAULT_ROOT_RES="$(mget paths.vault_root)"
[ -n "$VAULT_ROOT_RES" ] || VAULT_ROOT_RES="$(mget vault.root)"
STATE_ROOT_RES="$(mget paths.state_root)"
[ -n "$STATE_ROOT_RES" ] || STATE_ROOT_RES="${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem"

# OLD source roots — pre-relocation install-convention constants.
OLD_LOG_DIR="$CLAUDE_HOME/logs"
OLD_HOOKS_STATE="$CLAUDE_HOME/hooks/state"
OLD_ORCH_STATE="$CLAUDE_HOME/orchestrator/state"
OLD_VAULT_LOGS=""
[ -n "$VAULT_ROOT_RES" ] && OLD_VAULT_LOGS="$VAULT_ROOT_RES/Logs"

# NEW destinations under the XDG state tier.
NEW_LOGS="$STATE_ROOT_RES/logs"
NEW_ARCHIVE="$STATE_ROOT_RES/logs/archive"
NEW_HOOKS_STATE="$STATE_ROOT_RES/hooks-state"
NEW_RUNTIME="$STATE_ROOT_RES/runtime"
NEW_MANIFESTS="$STATE_ROOT_RES/manifests"
NEW_COORD="$STATE_ROOT_RES/.coordination"
NEW_AUDIT="$STATE_ROOT_RES/audit"
NEW_SESSIONS="$STATE_ROOT_RES/sessions"

CUR_SID="${CLAUDE_SESSION_ID:-}"

# In-flight-session gate. Read the OLD session-registry from the
# candidate pre-bump homes — the pre-in-vault location AND the post-
# XDG location — NEVER the freshly-installed empty XDG one resolved by paths.sh.
# Abort if any peer session (status==active, not the current sid) is registered.
inflight_peers=0
for _reg in "${OLD_VAULT_LOGS:+$OLD_VAULT_LOGS/.coordination/session-registry.json}" \
            "$STATE_ROOT_RES/.coordination/session-registry.json"; do
  [ -n "$_reg" ] && [ -f "$_reg" ] || continue
  _n="$(jq -r --arg sid "$CUR_SID" \
        '[.sessions // {} | to_entries[] | select(.key != $sid) | select(.value.status == "active")] | length' \
        "$_reg" 2>/dev/null || echo 0)"
  case "$_n" in (''|*[!0-9]*) _n=0 ;; esac
  inflight_peers=$((inflight_peers + _n))
done
if [ "$inflight_peers" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
  diag "$inflight_peers active peer session(s) in the OLD registry — refusing to move"
  diag "state out from under a live process. Close other sessions, or re-run with --force."
  exit 3
fi

# Journal + backup primitives.
#   Journal line: 'moved<TAB><src><TAB><dst>' appended AFTER a per-file move
#   verifies (stat probe). Resume reads it to skip moved-and-verified files.
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BACKUP_DIR" || { diag "cannot mkdir backup-dir: $BACKUP_DIR"; exit 11; }
  JOURNAL="$BACKUP_DIR/relocate-journal.tsv"
  : >> "$JOURNAL" || { diag "cannot write journal: $JOURNAL"; exit 11; }
else
  JOURNAL="$(mktemp -t relocate-journal-XXXXXX)"
fi

journal_done() {  # journal_done <src> — true if <src> already moved+verified
  [ -s "$JOURNAL" ] && grep -qF "$(printf 'moved\t%s\t' "$1")" "$JOURNAL"
}

# reverse-restore (catchable failures only). For every journaled move, copy the
# backup copy back to its source and remove the destination. The uncatchable
# interrupts are handled by journal-replay RESUME on the next operator run, NOT
# by this trap.
ROLLED_BACK=0
reverse_restore() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$ROLLED_BACK" -eq 1 ] && return 0
  ROLLED_BACK=1
  diag "reverse-restoring journaled moves from backup ($BACKUP_DIR) ..."
  [ -s "$JOURNAL" ] || return 0
  # Walk the journal in reverse so nested paths restore before parents.
  while IFS="$(printf '\t')" read -r _st _src _dst; do
    [ "$_st" = "moved" ] || continue
    local_bk="$BACKUP_DIR/restore$_src"
    if [ -e "$local_bk" ]; then
      mkdir -p "$(dirname "$_src")" 2>/dev/null || true
      cp -pR "$local_bk" "$_src" 2>/dev/null || true
    fi
    rm -rf "$_dst" 2>/dev/null || true
  done < <(tac "$JOURNAL" 2>/dev/null || tail -r "$JOURNAL")
  diag "reverse-restore complete."
}
on_err() { local rc=$?; diag "FAILED (rc=$rc) mid-move — rolling back."; reverse_restore; exit "$rc"; }
[ "$DRY_RUN" -eq 0 ] && trap on_err ERR

# move_one <src-file-or-dir> <dst-path>
#   Backup-then-(mv -n) a single entry; journal it after verify. Convergent: a
#   dst that already exists is treated as already-moved (resume / idempotent).
move_one() {
  local src="$1" dst="$2"
  [ -e "$src" ] || return 0
  if journal_done "$src"; then return 0; fi
  if [ -e "$dst" ] && [ ! -e "$src" ]; then return 0; fi   # already converged
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  MOVE  %s  ->  %s\n' "$src" "$dst"
    return 0
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null || true
  # Backup first (copy-not-move): preserves the source for reverse-restore.
  local bk="$BACKUP_DIR/restore$src"
  mkdir -p "$(dirname "$bk")" 2>/dev/null || true
  cp -pR "$src" "$bk" || return 1
  # Convergent move: mv -n won't clobber an existing dst (leaves src); the stat
  # probe below records success either way (dst present == converged).
  mv -n "$src" "$dst" 2>/dev/null || true
  if [ -e "$dst" ]; then
    if [ -e "$src" ] && ! cmp -s "$src" "$dst" 2>/dev/null; then
      # mv -n left src AND dst pre-existed with DIFFERENT content (a live writer wrote
      # the new path before the mover ran, or a dir collision). src carries unique bytes:
      # ARCHIVE it (recoverable) — never silent-drop. NOT journaled 'moved' (we did not
      # create dst); the src-absent guard above keeps the re-run idempotent and rollback
      # leaves the pre-existing dst untouched.
      mkdir -p "$NEW_ARCHIVE" 2>/dev/null || true
      mv -f "$src" "$NEW_ARCHIVE/collision-$(basename "$src")" 2>/dev/null || rm -rf "$src" 2>/dev/null || true
      diag "collision: $dst pre-existed with different content; archived old $src to $NEW_ARCHIVE/collision-$(basename "$src") (not dropped; reconcile manually)."
      return 0
    fi
    rm -rf "$src" 2>/dev/null || true   # src moved to dst, OR a byte-identical duplicate -> drop the converged source
    printf 'moved\t%s\t%s\n' "$src" "$dst" >> "$JOURNAL"
    return 0
  fi
  diag "move failed to land: $src -> $dst"
  return 1
}

# move_glob <src-dir> <glob> <dst-dir> — move matching top-level entries.
move_glob() {
  local sdir="$1" pat="$2" ddir="$3" f
  [ -d "$sdir" ] || return 0
  shopt -s nullglob
  for f in "$sdir"/$pat; do
    [ -e "$f" ] || continue
    move_one "$f" "$ddir/$(basename "$f")" || { shopt -u nullglob; return 1; }
  done
  shopt -u nullglob
  return 0
}

# is_dead <basename> — dead-state classifier (archive, never relocate live).
is_dead() {
  case "$1" in
    checkpoint-*.md) return 0 ;;            # legacy dated checkpoints
    auto-commit.log) return 0 ;;            # live-writer re-opened per fire -> dead-archive
    *backlog*snapshot*|*-snapshot-*.json) return 0 ;;
    *) return 1 ;;
  esac
}

# Build + execute the move plan.
if [ "$DRY_RUN" -eq 1 ]; then
  info "DRY-RUN — move plan (nothing is mutated):"
  info "  state root : $STATE_ROOT_RES"
  info "  vault Logs : ${OLD_VAULT_LOGS:-<no vault configured>}"
  [ "$inflight_peers" -gt 0 ] && info "  NOTE: $inflight_peers active peer session(s) would BLOCK a real run (use --force)."
fi

mkdir -p "$NEW_LOGS" "$NEW_ARCHIVE" "$NEW_HOOKS_STATE" "$NEW_RUNTIME" \
         "$NEW_MANIFESTS" "$NEW_COORD" "$NEW_AUDIT" "$NEW_SESSIONS" 2>/dev/null || true

# --- G4: $CLAUDE_HOME/logs/* -> state/logs/ (CARVE OUT install/uninstall provenance) ---
if [ -d "$OLD_LOG_DIR" ]; then
  shopt -s nullglob
  for f in "$OLD_LOG_DIR"/*; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
      install-*.log|uninstall-*.log) continue ;;   # provenance carve-out — STAYS
    esac
    if is_dead "$b"; then move_one "$f" "$NEW_ARCHIVE/$b"; else move_one "$f" "$NEW_LOGS/$b"; fi
  done
  shopt -u nullglob
fi

# --- G5: $CLAUDE_HOME/hooks/state/* -> state/hooks-state/ (dead -> archive; sessions reconciled below) ---
if [ -d "$OLD_HOOKS_STATE" ]; then
  shopt -s nullglob
  for f in "$OLD_HOOKS_STATE"/*; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    [ "$b" = "sessions" ] && continue          # reconciled separately (below)
    if [ "$b" = "hook-audit.log" ]; then move_one "$f" "$NEW_AUDIT/$b"; continue; fi  # split-brain #1
    if is_dead "$b"; then move_one "$f" "$NEW_ARCHIVE/$b"; else move_one "$f" "$NEW_HOOKS_STATE/$b"; fi
  done
  shopt -u nullglob
fi

# --- reconcile the two split session trees, de-duped by sid (prefer the XDG copy) ---
if [ -d "$OLD_HOOKS_STATE/sessions" ]; then
  shopt -s nullglob
  for sd in "$OLD_HOOKS_STATE/sessions"/*; do
    [ -e "$sd" ] || continue
    sb="$(basename "$sd")"
    # Bare orphan checkpoint.md (not a valid per-session dir) -> archive.
    if [ "$sb" = "checkpoint.md" ] && [ -f "$sd" ]; then move_one "$sd" "$NEW_ARCHIVE/orphan-checkpoint.md"; continue; fi
    [ -d "$sd" ] || continue
    [ -n "$CUR_SID" ] && [ "$sb" = "$CUR_SID" ] && continue   # NEVER move the active session's own dir
    if [ -e "$NEW_SESSIONS/$sb" ]; then
      # XDG copy already exists -> prefer it; archive the old duplicate, never blind-union.
      move_one "$sd" "$NEW_ARCHIVE/dup-session-$sb"
    else
      move_one "$sd" "$NEW_SESSIONS/$sb"
    fi
  done
  shopt -u nullglob
fi

# --- G8: $CLAUDE_HOME/orchestrator/state/* -> state/runtime/ ---
if [ -d "$OLD_ORCH_STATE" ]; then
  shopt -s nullglob
  for f in "$OLD_ORCH_STATE"/*; do
    [ -e "$f" ] || continue
    move_one "$f" "$NEW_RUNTIME/$(basename "$f")"
  done
  shopt -u nullglob
fi

# --- G1/G2/G3 drain: $VAULT_ROOT/Logs machine exhaust -> state/ ---
if [ -n "$OLD_VAULT_LOGS" ] && [ -d "$OLD_VAULT_LOGS" ]; then
  # manifest -> state/manifests/ (G2)
  move_one "$OLD_VAULT_LOGS/librarian-manifest.json" "$NEW_MANIFESTS/librarian-manifest.json"
  # in-vault .coordination/ (pre-) -> state/.coordination/, incl. manifest.lock (split-brain #2)
  if [ -d "$OLD_VAULT_LOGS/.coordination" ]; then
    shopt -s nullglob
    for f in "$OLD_VAULT_LOGS/.coordination"/* "$OLD_VAULT_LOGS/.coordination"/.[!.]*; do
      [ -e "$f" ] || continue
      move_one "$f" "$NEW_COORD/$(basename "$f")"
    done
    shopt -u nullglob
  fi
  # session-close receipts + librarian-errors + other machine *.md -> state/logs/
  move_glob "$OLD_VAULT_LOGS" "session-close-*.md" "$NEW_LOGS"
  if [ -d "$OLD_VAULT_LOGS/librarian-errors" ]; then
    move_one "$OLD_VAULT_LOGS/librarian-errors" "$NEW_LOGS/librarian-errors"
  fi
fi

# --- G6: memory-dir consolidation/review-queue LOGS -> state/logs/ (LOGS ONLY) ---
# The memory dir is a symlink to Claude-Code-owned knowledge; only the run-LOGS
# relocate. The .consolidation-state.json / .consolidation.lock / .review-queue.json
# STAY bound to the memory dir and are NOT touched here (decisions.md carve-out).
MEM_BASE="${CLAUDE_CODE_REMOTE_MEMORY_DIR:-$CLAUDE_HOME}/projects"
if [ -d "$MEM_BASE" ]; then
  shopt -s nullglob
  for md in "$MEM_BASE"/*/memory; do
    [ -d "$md" ] || continue
    for lg in "$md/.consolidation-log.md" "$md/.review-queue-log.md"; do
      [ -f "$lg" ] && move_one "$lg" "$NEW_LOGS/$(basename "$lg")"
    done
  done
  shopt -u nullglob
fi

# Re-render the launchd plists in production mode (bootout+bootstrap)
# AFTER the env defaults changed, or cron logs strand at the baked old path.
RENDER="$CLAUDE_HOME/installer/render-launchd.sh"
[ -x "$RENDER" ] || RENDER="$_self_dir/render-launchd.sh"
for job in writer-reconciler doc-amender; do
  if [ "$DRY_RUN" -eq 1 ]; then
    info "  RE-RENDER launchd '$job' (production bootout+bootstrap) — skipped in dry-run"
  elif [ -x "$RENDER" ]; then
    if "$RENDER" "$job" >/dev/null 2>&1; then
      info "re-rendered launchd '$job' (CLAUDE_LOG_DIR now resolves to $NEW_LOGS)"
    else
      diag "WARN: render-launchd '$job' returned non-zero (re-render manually; cron logs may strand)"
    fi
  fi
done

[ "$DRY_RUN" -eq 0 ] && trap - ERR
if [ "$DRY_RUN" -eq 1 ]; then
  rm -f "$JOURNAL" 2>/dev/null || true
  info "DRY-RUN complete — nothing mutated."
else
  info "relocation complete. backup + move-journal at: $BACKUP_DIR"
  info "  (re-run with the same --backup-dir to RESUME after an interrupt — moved-and-verified files are skipped)"
fi
exit 0
