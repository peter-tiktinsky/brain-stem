#!/bin/bash
# migration: 0002-session-registry-reshape
# min_from: v0.0.0
# applies_at: v1.0.2
#
# Forward-only idempotent migration demonstrator.
#
# Idempotent JSON reshape: read session-registry.json; if it is missing a new
# key, jq-add it with a default and atomic-write. Converge-if-needed by the
# key-presence probe (re-running against an already-reshaped registry is a
# no-op). Tolerates the lazy-not-yet-created case (no file => no-op; registry.sh
# creates the new shape on first run) — honors the v0.0.0 authoring contract.
#
# Forward substrate demonstrator: no current defect requires it.
set -u

CLAUDE_HOME="${CLAUDE_HOME:-}"
REG="${MIGRATION_SESSION_REGISTRY:-$CLAUDE_HOME/hooks/state/session-registry.json}"
NEW_KEY="reconcile_epoch"

# Tolerate the oldest/empty precondition: no registry yet -> no-op (lazy-created).
if [ -z "$CLAUDE_HOME" ] || [ ! -f "$REG" ]; then
  printf '0002: session-registry absent (%s) — no-op (lazy-created at new shape on first run)\n' "${REG:-<unset>}" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '0002: jq not on PATH — cannot reshape registry; no-op (registry untouched)\n' >&2
  exit 0
fi
if ! jq -e . "$REG" >/dev/null 2>&1; then
  printf '0002: session-registry is not valid JSON (%s) — no-op (refuse to reshape a corrupt file)\n' "$REG" >&2
  exit 0
fi

# --- structural probe: is the new key already present? --------------------
if jq -e --arg k "$NEW_KEY" 'has($k)' "$REG" >/dev/null 2>&1; then
  printf '0002: session-registry already has .%s — converge no-op\n' "$NEW_KEY" >&2
  exit 0
fi

printf '0002: session-registry missing .%s — adding default; atomic-write\n' "$NEW_KEY" >&2
tmp="$REG.upgrade.$$"
if jq --arg k "$NEW_KEY" '. + {($k): 0}' "$REG" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  mv -f "$tmp" "$REG" || { rm -f "$tmp"; printf '0002: atomic mv failed\n' >&2; exit 1; }
  printf '0002: added .%s=0 to session-registry\n' "$NEW_KEY" >&2
  exit 0
else
  rm -f "$tmp"
  printf '0002: jq reshape failed\n' >&2
  exit 1
fi
