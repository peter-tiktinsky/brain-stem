#!/bin/bash
# migration: 0004-relocate-operational-exhaust
# min_from: v0.0.0
# applies_at: v1.3.0
# split migration. Cheap, idempotent, in-$CLAUDE_HOME JSON-only reshape; same
# CLASS as 0001-0003. The dangerous out-of-$CLAUDE_HOME bulk move lives in the
# SEPARATE operator-gated installer/relocate-state.sh (the shared rollback
# envelope cannot snapshot out-of-home files — migration-plan).
# What it does: pins the relocated operational-exhaust paths into
# user-manifest.json .paths.* so the install is unambiguously on the XDG STATE
# tier. The new paths.sh defaults already resolve here (Waves 1-3), but pinning
# the manifest makes the new layout the explicit override-tier SoT and provides
# the migrations_applied[] high-water marker for v1.3.0. Additive-only: an
# existing .paths.* override is NEVER clobbered (respects user/test overrides).
# Idempotent: probe ".paths.log_dir already present?" -> converge no-op
# (byte-stable on re-run; the `//`-guarded jq would be a no-op anyway).
# Tolerates the oldest/empty precondition (no manifest -> no-op; the flipped
# paths.sh defaults already resolve to the new locations) — honors the v0.0.0
# legacy-adopt authoring contract.
set -u

CLAUDE_HOME="${CLAUDE_HOME:-}"
# One env seam for test isolation (matches 0002:18 / 0003:19). Disk-true manifest
# home is $CLAUDE_HOME/user-manifest.json (paths.sh:35, session-start.sh,
# user-manifest-read.sh:38) — NOT under governance/.
MANIFEST="${MIGRATION_USER_MANIFEST:-$CLAUDE_HOME/user-manifest.json}"

# Effective state-root DEFAULT — identical resolution to paths.sh:58. Only used
# when the manifest carries no .paths.state_root override.
STATE_ROOT_DEFAULT="${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem"

# Tolerate the oldest/empty precondition: no manifest yet -> no-op (the flipped
# paths.sh defaults already resolve to the XDG state tier; nothing to pin).
if [ -z "$CLAUDE_HOME" ] || [ ! -f "$MANIFEST" ]; then
  printf '0004: user-manifest absent (%s) — no-op (paths.sh defaults already resolve to the XDG state tier)\n' "${MANIFEST:-<unset>}" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '0004: jq not on PATH — cannot reshape manifest; no-op (manifest untouched)\n' >&2
  exit 0
fi
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  printf '0004: user-manifest is not valid JSON (%s) — no-op (refuse to reshape a corrupt file)\n' "$MANIFEST" >&2
  exit 0
fi

# --- structural probe: is .paths.log_dir already present? -------------------
if jq -e '.paths.log_dir' "$MANIFEST" >/dev/null 2>&1; then
  printf '0004: user-manifest already carries .paths.log_dir — converge no-op\n' >&2
  exit 0
fi

printf '0004: pinning relocated .paths.* (log_dir/hooks_state/state_root) into user-manifest; atomic-write\n' >&2
tmp="$MANIFEST.upgrade.$$"
# Additive-only: set state_root to the default ONLY if absent, then derive
# log_dir + hooks_state from the EFFECTIVE state_root (existing override or the
# just-set default) — again only if absent. An existing override on any key is
# preserved (the `//` short-circuits).
if jq --arg def_sr "$STATE_ROOT_DEFAULT" '
  .paths = (.paths // {})
  | .paths.state_root = (.paths.state_root // $def_sr)
  | (.paths.state_root) as $sr
  | .paths.log_dir = (.paths.log_dir // ($sr + "/logs"))
  | .paths.hooks_state = (.paths.hooks_state // ($sr + "/hooks-state"))
' "$MANIFEST" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  mv -f "$tmp" "$MANIFEST" || { rm -f "$tmp"; printf '0004: atomic mv failed\n' >&2; exit 1; }
  printf '0004: pinned .paths.log_dir + .paths.hooks_state (+ .paths.state_root if unset) to the XDG state tier\n' >&2
  exit 0
else
  rm -f "$tmp"
  printf '0004: jq reshape failed\n' >&2
  exit 1
fi
