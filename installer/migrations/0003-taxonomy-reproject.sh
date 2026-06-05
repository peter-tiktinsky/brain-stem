#!/bin/bash
# migration: 0003-taxonomy-reproject
# min_from: v0.0.0
# applies_at: v1.0.2
#
# Forward-only idempotent migration demonstrator.
#
# Idempotent taxonomy re-projection: read the adopter
# overlay-master.json :: tagging.taxonomy.dimension_prefixes, project each
# through the new foundation taxonomy shape, write back. Converge-if-needed by
# detecting the already-projected shape (a per-dimension marker key). Tolerates
# the oldest/empty precondition (no overlay / no taxonomy block => no-op) —
# honors the v0.0.0 legacy-adopt authoring contract.
#
# Forward substrate demonstrator: no current defect requires it.
set -u

CLAUDE_HOME="${CLAUDE_HOME:-}"
OVERLAY="${MIGRATION_OVERLAY_MASTER:-$CLAUDE_HOME/governance/overlay-master.json}"

# Tolerate the oldest/empty precondition: no overlay yet -> no-op.
if [ -z "$CLAUDE_HOME" ] || [ ! -f "$OVERLAY" ]; then
  printf '0003: overlay-master absent (%s) — no-op (nothing to reproject)\n' "${OVERLAY:-<unset>}" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '0003: jq not on PATH — cannot reproject taxonomy; no-op (overlay untouched)\n' >&2
  exit 0
fi
if ! jq -e . "$OVERLAY" >/dev/null 2>&1; then
  printf '0003: overlay-master is not valid JSON (%s) — no-op\n' "$OVERLAY" >&2
  exit 0
fi

# No taxonomy block / no dimension_prefixes -> nothing to reproject (oldest precondition).
if ! jq -e '.tagging.taxonomy.dimension_prefixes' "$OVERLAY" >/dev/null 2>&1; then
  printf '0003: no .tagging.taxonomy.dimension_prefixes in overlay — no-op\n' >&2
  exit 0
fi

# --- structural probe: is the projected shape already present? ------------
# The new foundation shape carries a `.tagging.taxonomy.projected_schema`
# version marker == 2. If it is already 2, the reprojection has run -> no-op.
proj="$(jq -r '.tagging.taxonomy.projected_schema // empty' "$OVERLAY" 2>/dev/null || true)"
if [ "$proj" = "2" ]; then
  printf '0003: taxonomy already projected (projected_schema=2) — converge no-op\n' >&2
  exit 0
fi

printf '0003: projecting dimension_prefixes through the new taxonomy shape; atomic-write\n' >&2
tmp="$OVERLAY.upgrade.$$"
# Re-project: stamp projected_schema=2; normalize each dimension prefix into the
# new {prefix, projected:true} object shape, leaving already-object entries
# untouched (so the projection is itself convergent across re-runs).
if jq '
  .tagging.taxonomy.projected_schema = 2
  | .tagging.taxonomy.dimension_prefixes = (
      (.tagging.taxonomy.dimension_prefixes // {})
      | with_entries(
          .value = (
            if (.value | type) == "object" then .value
            else {prefix: .value, projected: true}
            end
          )
        )
    )
' "$OVERLAY" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  mv -f "$tmp" "$OVERLAY" || { rm -f "$tmp"; printf '0003: atomic mv failed\n' >&2; exit 1; }
  printf '0003: reprojected taxonomy (projected_schema=2)\n' >&2
  exit 0
else
  rm -f "$tmp"
  printf '0003: jq reprojection failed\n' >&2
  exit 1
fi
