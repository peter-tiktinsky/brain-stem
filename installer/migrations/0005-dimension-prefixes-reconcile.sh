#!/bin/bash
# migration: 0005-dimension-prefixes-reconcile
# min_from: v0.0.0
# applies_at: v1.13.0
#
# converge the three LIVE dimension_prefixes populations
# to the canonical ARRAY shape (— dimension_prefixes is a list of prefix
# slugs; the `--values` dict is retired). Three shapes live in-tree from before
# the shape-flip:
#   1. hand-authored ARRAY   ["status","log","project"]        -> already canonical (no-op)
#   2. tag-extension DICT     {"priority":["high","low"]}       -> keys are the slugs
#   3. 0003-projected OBJECT   {"status":{prefix,projected},...} -> keys are the slugs
# For (2)/(3) the object KEYS ARE the canonical prefix slugs; extract them
# order-preserving (dedup belt-and-suspenders) into the canonical array. An
# already-array leaf is left byte-untouched. Convergent + idempotent: after the
# conversion the leaf is an array, so a re-run is a converge no-op.
#
# Sequenced AFTER 0003 (array-tolerance) and 0004; 0003 stamps projected_schema=2
# on the object populations and this migration then canonicalizes the shape, so a
# shape-flip has a forward path on EVERY seeded adopter (no install.sh exit 41).
#
# Tolerates the oldest/empty precondition (no overlay / no dimension_prefixes ->
# no-op) — honors the v0.0.0 legacy-adopt authoring contract.
set -u

CLAUDE_HOME="${CLAUDE_HOME:-}"
# One env seam for test isolation (matches 0003:19).
OVERLAY="${MIGRATION_OVERLAY_MASTER:-$CLAUDE_HOME/governance/overlay-master.json}"

# Tolerate the oldest/empty precondition: no overlay yet -> no-op.
if [ -z "$CLAUDE_HOME" ] || [ ! -f "$OVERLAY" ]; then
  printf '0005: overlay-master absent (%s) — no-op (nothing to reconcile)\n' "${OVERLAY:-<unset>}" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '0005: jq not on PATH — cannot reconcile dimension_prefixes; no-op (overlay untouched)\n' >&2
  exit 0
fi
if ! jq -e . "$OVERLAY" >/dev/null 2>&1; then
  printf '0005: overlay-master is not valid JSON (%s) — no-op\n' "$OVERLAY" >&2
  exit 0
fi

# No taxonomy block / no dimension_prefixes -> nothing to reconcile (oldest precondition).
if ! jq -e '.tagging.taxonomy.dimension_prefixes' "$OVERLAY" >/dev/null 2>&1; then
  printf '0005: no .tagging.taxonomy.dimension_prefixes in overlay — no-op\n' >&2
  exit 0
fi

# --- structural probe: is the leaf already the canonical ARRAY shape? --------
dp_type="$(jq -r '.tagging.taxonomy.dimension_prefixes | type' "$OVERLAY" 2>/dev/null || true)"
if [ "$dp_type" = "array" ]; then
  printf '0005: dimension_prefixes already the canonical array shape — converge no-op\n' >&2
  exit 0
fi

printf '0005: reconciling dimension_prefixes (%s) to the canonical array (order-preserving); atomic-write\n' "$dp_type" >&2
tmp="$OVERLAY.upgrade.$$"
# Object (dict / {prefix,projected}) -> canonical array: the object KEYS are the
# prefix slugs; extract them order-preserving (keys_unsorted retains insertion
# order), with an explicit dedup (belt-and-suspenders; object keys are unique).
if jq '
  .tagging.taxonomy.dimension_prefixes = (
    (.tagging.taxonomy.dimension_prefixes | keys_unsorted)
    | reduce .[] as $k ([]; if any(.[]; . == $k) then . else . + [$k] end)
  )
' "$OVERLAY" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  # Intentional atomic-write within this migration's own transaction (temp-write
  # + atomic rename); migrations run at install-time before the write-time
  # governance chain is armed. run-migrations halts the chain on a non-zero exit.
  mv -f "$tmp" "$OVERLAY" || { rm -f "$tmp"; printf '0005: atomic mv failed\n' >&2; exit 1; }
  printf '0005: reconciled dimension_prefixes to the canonical array shape\n' >&2
  exit 0
else
  rm -f "$tmp"
  printf '0005: jq reconciliation failed\n' >&2
  exit 1
fi
