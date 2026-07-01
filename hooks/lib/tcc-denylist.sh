#!/bin/bash
# hooks/lib/tcc-denylist.sh — shared denylist of macOS TCC-protected directory
# prefixes a launchd StandardOut/ErrorPath must never resolve into. Source this
# file — do not execute it:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/tcc-denylist.sh"
#   tcc_stdpath_is_protected "/abs/path/to/file.log" && echo PROTECTED
# Why this exists: launchd opens a job's StandardOut/ErrorPath redirect target
# BEFORE it execs the program. If that target sits under a TCC-protected
# directory, the open is denied and launchd aborts the spawn with EX_CONFIG
# (exit code 78) — the job never runs and dies SILENTLY (there is no output,
# because the output sink is the very thing that failed). A render-time check
# against this denylist turns that silent death into a loud, actionable failure.
# Protected prefixes (all $HOME-relative unless absolute):
#   ~/Desktop  ~/Documents  ~/Downloads          (TCC user-data domains)
#   ~/Library/Mobile Documents                    (iCloud Drive)
#   ~/Library/CloudStorage                        (third-party cloud mounts)
#   ~/.Trash
#   /Volumes/*                                    (removable / network mounts)
# Deliberately NOT ~/Library broadly — ~/Library/Logs is the canonical non-TCC
# log home and MUST pass. The recommended non-TCC log sink is the XDG state tier
# (~/.local/state/brain-stem/logs, the CLAUDE_LOG_DIR default).
# Bash 3.2 clean: no associative arrays; the prefix set is a newline-delimited
# list so a prefix containing a space (e.g. "Mobile Documents") is preserved.

# tcc_protected_prefixes — emit the absolute TCC-protected prefixes, one per
# line, with $HOME expanded. This is the SINGLE source of the denylist: the
# predicate below and any external scanner both read the set from here.
tcc_protected_prefixes() {
  local _home="${HOME:-}"
  if [ -n "$_home" ]; then
    printf '%s\n' \
      "$_home/Desktop" \
      "$_home/Documents" \
      "$_home/Downloads" \
      "$_home/Library/Mobile Documents" \
      "$_home/Library/CloudStorage" \
      "$_home/.Trash"
  fi
  printf '%s\n' "/Volumes"
}

# tcc_stdpath_is_protected <abs-path> — return 0 if <abs-path> equals or nests
# under any TCC-protected prefix, 1 otherwise. On a hit, TCC_MATCHED_PREFIX holds
# the matched prefix (for caller diagnostics); it is cleared on a miss. An empty
# argument is a miss.
TCC_MATCHED_PREFIX=""
tcc_stdpath_is_protected() {
  local _p="$1" _pfx
  TCC_MATCHED_PREFIX=""
  [ -n "$_p" ] || return 1
  while IFS= read -r _pfx; do
    [ -n "$_pfx" ] || continue
    case "$_p" in
      "$_pfx"|"$_pfx"/*) TCC_MATCHED_PREFIX="$_pfx"; return 0 ;;
    esac
  done <<EOF
$(tcc_protected_prefixes)
EOF
  return 1
}
