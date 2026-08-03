#!/bin/bash
# migration: 0007-retired-surface-removal
# min_from: v0.0.0
# applies_at: v1.13.0
#
# Remove the retired/inert shipped surfaces from an existing adopter install at the
# v1.13.0 upgrade. Deleting a file from the ship tree does NOT delete it from an existing
# install: the FOUNDATION-REPLACE walk is new-manifest-driven, so a path dropped from the
# shipped manifest is never visited and its on-disk copy orphans; and the Step-12.5 hook
# reconciler is ADDS-only, so it never removes a de-listed hook tuple. This migration
# closes that gap by NAMED path (never a bare manifest-diff prune — that would delete a
# demoted-to-adopter-owned seed-once file).
#
# Arms (executed in THIS order — the non-destructive settings de-wire runs FIRST so a
# python3-absent failure fails CLOSED before anything is removed; recovery is a re-run):
#   (c) de-wire the retired stop-drift-scan Stop-hook tuple from the adopter's live
#       settings.json (the reconciler is ADDS-only, so it would otherwise re-add the tuple
#       forever and every Stop turn would error on the now-missing hook). Targeted +
#       idempotent, preserving every OTHER hook entry. FAIL-CLOSED on missing python3
#       (rc 1) — a silent skip would leave the dead tuple wired. python3 is required ONLY
#       for this arm. RUNS FIRST: on a python3-absent home it exits 1 BEFORE arm (a)
#       removes anything, so the retired code files SURVIVE and the tuple stays wired (a
#       self-consistent prior-release state — no dangling Stop-hook wire); recovery is
#       re-running install.sh --apply with python3 present, which converges the chain.
#   (a) remove the retired $CLAUDE_HOME foundation code files (the four dead service/lib
#       files + the three root-template trio + the retired plan-printer + the
#       memory-consolidation settings fragment), sha-guarded against the frozen baseline
#       manifest: on-disk sha == baseline sha (adopter-unmodified) -> remove; on-disk sha
#       differs, OR the baseline is unresolvable -> sidecar-rename to
#       <path>.foundation-retired (never a silent rm of unproven adopter bytes; the dpkg
#       .dpkg-old posture); absent -> no-op (idempotent).
#   (b) defensive remove-if-present of the retired runtime outputs (FILES ONLY, never
#       dirs): $CLAUDE_HOME/state/active-gates.json (+ a guarded rmdir of an emptied
#       state/ dir), $CLAUDE_HOME/hooks/lib/l3-writer-registry.json,
#       $HOOKS_STATE/live-guard-crashes.log, $HOOKS_STATE/<sid>/active-plans.txt. It NEVER
#       touches a $HOOKS_STATE dir, the tripwire.log / tripwire-forensics.log /
#       hook-audit.log / memory-schema-advisory-history.jsonl, or the legacy
#       ~/.claude/hooks/state/ tree.
#   (d) remove a stale plans-root _archive.md UNCONDITIONALLY: the file is machine-owned
#       by the governance model (registered generated_by=librarian; pre-write-guard.sh
#       denies hand-writes to librarian-generated root files), so byte-preservation
#       guards would defend a forbidden state; absent -> no-op.
#
# Root resolution (the 0006 seam): MIGRATION_PLANS_ROOT (test seam) -> PLANS_DIR_DEAD
# (dead-root redirect) -> PLANS_DIR -> $HOME/.claude-plans. CLAUDE_HOME is passed by
# run-migrations.sh; HOOKS_STATE resolves via HOOKS_STATE_OVERRIDE (test seam) ->
# HOOKS_STATE -> CLAUDE_STATE_ROOT/hooks-state -> the XDG default. An absent target for any
# arm is a no-op. Convergent + idempotent: a second run finds every named surface already
# removed / sidecar'd / de-wired and changes nothing. A fresh install (no retired surfaces
# on disk) is a full no-op.
#
# bash-3.2 clean; set -u.
set -u

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
case "$CLAUDE_HOME_RES" in */) CLAUDE_HOME_RES="${CLAUDE_HOME_RES%/}" ;; esac
BASELINE="$CLAUDE_HOME_RES/governance/.installed-baseline-manifest.json"

# --- sha helpers (pure shell; arms (a)/(b)/(d) never require python3) ---------
file_sha() {  # $1 = abs path -> sha256 hex, or "" if no sha tool / unreadable
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    printf ''
  fi
}
baseline_sha() {  # $1 = repo-relative path -> recorded sha256, or "" if unresolvable
  [ -f "$BASELINE" ] || { printf ''; return 0; }
  # The manifest is pretty-printed with sorted keys (mode < path < sha256 < size), so the
  # sha256 line is exactly the line AFTER the path line — pure grep/sed, no JSON parser.
  grep -F -A1 "\"path\": \"$1\"" "$BASELINE" 2>/dev/null \
    | grep '"sha256"' | head -1 \
    | sed -E 's/.*"sha256"[[:space:]]*:[[:space:]]*"([0-9a-fA-F]+)".*/\1/'
}

# --- (c) settings.json stop-drift-scan de-wire (python3; FAIL-CLOSED) ---------
SETTINGS="$CLAUDE_HOME_RES/settings.json"
if [ -f "$SETTINGS" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    printf '0007: python3 not on PATH — cannot safely de-wire the stop-drift-scan Stop-hook tuple from settings.json; FAIL-CLOSED (rc 1). Remediation: install python3 (>=3.6) and re-run the upgrade so the migration chain can complete.\n' >&2
    exit 1
  fi
  python3 - "$SETTINGS" <<'PY'
import json, os, sys, tempfile
p = sys.argv[1]
try:
    with open(p, encoding="utf-8") as fh:
        d = json.load(fh)
except (OSError, ValueError):
    sys.stderr.write("0007: settings.json unreadable/unparsable — de-wire skipped (no-op)\n")
    sys.exit(0)

def cmd(h):
    return (h.get("command", "") or "") if isinstance(h, dict) else ""

changed = False
hooks_root = d.get("hooks")
if isinstance(hooks_root, dict):
    for ev, groups in hooks_root.items():
        if not isinstance(groups, list):
            continue
        for g in groups:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                before = g["hooks"]
                after = [h for h in before if "stop-drift-scan" not in cmd(h)]
                if len(after) != len(before):
                    g["hooks"] = after
                    changed = True

if not changed:
    sys.stderr.write("0007: settings.json carries no stop-drift-scan tuple — de-wire no-op (idempotent)\n")
    sys.exit(0)

dname = os.path.dirname(p) or "."
fd, tmp = tempfile.mkstemp(dir=dname, prefix=".settings.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    try:
        os.chmod(tmp, os.stat(p).st_mode)
    except OSError:
        pass
    os.replace(tmp, p)
    sys.stderr.write("0007: de-wired the stop-drift-scan Stop-hook tuple from settings.json\n")
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
sys.exit(0)
PY
  rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
fi

# --- (a) named $CLAUDE_HOME code files: sha-guarded remove / sidecar ----------
# This roster is the retirement's OWN executor — it names each retired path in order to
# remove it from adopter homes (the FOUNDATION-REPLACE walk never visits a de-listed
# path). The last two entries close the orphan roster: the retired plan-printer (installed
# v1.11.0 through v1.12.1) and the memory-consolidation settings fragment (a since-retired
# opt-in, installed through v1.12.1). Both are baseline-sha resolvable, so the sha-guard
# cleanly removes an adopter-unmodified copy and sidecars a modified one.
RETIRED_CODE="
skills/librarian/capabilities/plan-archive.sh
hooks/stop-drift-scan.sh
hooks/lib/active-gates-rebuild.sh
hooks/lib/l3-registry-audit.sh
templates/spec-template.md
templates/tasks-template.md
templates/handoff-template.md
installer/cron-dispatch.sh
templates/settings-fragments/memory-consolidation.json
"
for rel in $RETIRED_CODE; do
  abs="$CLAUDE_HOME_RES/$rel"
  [ -e "$abs" ] || continue                     # absent -> no-op (idempotent)
  bsha="$(baseline_sha "$rel")"
  if [ -n "$bsha" ]; then
    dsha="$(file_sha "$abs")"
    if [ -n "$dsha" ] && [ "$dsha" = "$bsha" ]; then
      rm -f "$abs" && printf '0007: removed adopter-unmodified %s\n' "$rel" >&2
      continue
    fi
  fi
  # sha mismatch, or baseline/sha unresolvable -> sidecar-rename (never a silent rm).
  mv -f "$abs" "$abs.foundation-retired" 2>/dev/null \
    && printf '0007: sidecar-renamed (adopter-modified or no-baseline) %s -> %s.foundation-retired\n' "$rel" "$rel" >&2
done

# --- (b) defensive remove-if-present of retired runtime outputs (files only) --
HOOKS_STATE_RES="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}"
case "$HOOKS_STATE_RES" in */) HOOKS_STATE_RES="${HOOKS_STATE_RES%/}" ;; esac

_ag="$CLAUDE_HOME_RES/state/active-gates.json"
if [ -f "$_ag" ]; then
  rm -f "$_ag" && printf '0007: removed retired state/active-gates.json\n' >&2
  # guarded: rmdir removes state/ ONLY if now empty (this file was its only writer).
  rmdir "$CLAUDE_HOME_RES/state" 2>/dev/null && printf '0007: removed now-empty state/ dir\n' >&2 || true
fi
_l3="$CLAUDE_HOME_RES/hooks/lib/l3-writer-registry.json"
[ -f "$_l3" ] && { rm -f "$_l3" && printf '0007: removed retired hooks/lib/l3-writer-registry.json\n' >&2; }
_lgc="$HOOKS_STATE_RES/live-guard-crashes.log"
[ -f "$_lgc" ] && { rm -f "$_lgc" && printf '0007: removed retired live-guard-crashes.log\n' >&2; }
# per-session active-plans.txt — FILES ONLY, never the <sid>/ dirs, never any other file.
if [ -d "$HOOKS_STATE_RES" ]; then
  for _apf in "$HOOKS_STATE_RES"/*/active-plans.txt; do
    [ -f "$_apf" ] && { rm -f "$_apf" && printf '0007: removed retired %s\n' "$_apf" >&2; }
  done
fi

# --- (d) plans-root _archive.md UNCONDITIONAL removal (the 0006 seam) ---------
if [ -n "${MIGRATION_PLANS_ROOT:-}" ]; then
  PLANS_ROOT="$MIGRATION_PLANS_ROOT"
elif [ -n "${PLANS_DIR_DEAD:-}" ]; then
  PLANS_ROOT="$PLANS_DIR_DEAD"
elif [ -n "${PLANS_DIR:-}" ]; then
  PLANS_ROOT="$PLANS_DIR"
else
  PLANS_ROOT="$HOME/.claude-plans"
fi
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
_arch="$PLANS_ROOT/_archive.md"
[ -f "$_arch" ] && { rm -f "$_arch" && printf '0007: removed stale plans-root _archive.md (machine-owned; unconditional)\n' >&2; }

exit 0
