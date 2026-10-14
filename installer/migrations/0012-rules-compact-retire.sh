#!/bin/bash
# migration: 0012-rules-compact-retire
# min_from: v0.0.0
# applies_at: v1.19.0
#
# Remove the retired rules-compact librarian capability from an EXISTING adopter install
# at the v1.19.0 upgrade. Deleting a file from the ship tree does NOT delete it from an
# existing install: the FOUNDATION-REPLACE walk is new-manifest-driven, so a path dropped
# from the shipped manifest is never visited and its on-disk copy orphans. A NAMED-path
# migration is the only removal path (never a bare manifest-diff prune — that would delete
# a demoted-to-adopter-owned seed-once file). min_from is v0.0.0 because an absent target
# is a no-op, so the floor is irrelevant; applies_at is v1.19.0, the release that stops
# shipping the file.
#
# ONE arm, for ONE named path — skills/librarian/capabilities/rules-compact.sh —
# sha-guarded against the frozen baseline manifest
# ($CLAUDE_HOME/governance/.installed-baseline-manifest.json):
#   on-disk sha == baseline sha (adopter-unmodified)   -> rm -f + a stderr line
#   sha differs, OR the baseline is unresolvable       -> sidecar-rename to
#                                                         <path>.foundation-retired
#                                                         (never a silent rm of unproven
#                                                         adopter bytes; the dpkg
#                                                         .dpkg-old posture)
#   absent                                             -> no-op (idempotent)
# The arm touches exactly its one named path and nothing else. Convergent + idempotent:
# a second run finds the path already removed / sidecar'd and changes nothing. A fresh
# install (the file never shipped to it) is a full no-op.
#
# Advisories go to stderr; stdout stays clean for the runner. python3 is NOT required.
# bash-3.2 clean; set -u. Exit 0 always.
set -u

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
case "$CLAUDE_HOME_RES" in */) CLAUDE_HOME_RES="${CLAUDE_HOME_RES%/}" ;; esac
BASELINE="$CLAUDE_HOME_RES/governance/.installed-baseline-manifest.json"

# --- sha helpers (pure shell) -------------------------------------------------
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

# --- the one named path: sha-guarded remove / sidecar -------------------------
rel="skills/librarian/capabilities/rules-compact.sh"
abs="$CLAUDE_HOME_RES/$rel"
if [ -e "$abs" ]; then
  bsha="$(baseline_sha "$rel")"
  removed=0
  if [ -n "$bsha" ]; then
    dsha="$(file_sha "$abs")"
    if [ -n "$dsha" ] && [ "$dsha" = "$bsha" ]; then
      rm -f "$abs" && printf '0012: removed adopter-unmodified %s\n' "$rel" >&2 && removed=1
    fi
  fi
  if [ "$removed" -eq 0 ]; then
    # sha mismatch, or baseline/sha unresolvable -> sidecar-rename (never a silent rm).
    mv -f "$abs" "$abs.foundation-retired" 2>/dev/null \
      && printf '0012: sidecar-renamed (adopter-modified or no-baseline) %s -> %s.foundation-retired\n' "$rel" "$rel" >&2
  fi
fi

exit 0
