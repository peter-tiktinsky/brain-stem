#!/bin/bash
# spoke-resolve.sh — cwd→spoke-key resolution against the anchored-spoke registry.
# Implements the R-ARCH-13 collision-safe resolver and the R-ARCH-14 --project
# override validation (D2 surface-architecture). Sourced by the plan-creation
# writers (new-plan.sh, promote-from-inbox.sh); the resolution + collision +
# override logic lives in one place so both writers stay drift-resistant.
# The registry (governance/anchored-spoke-registry.json) maps cwd anchors to
# stable spoke keys. The stamped `project:` is the registry-resolved spoke key,
# NEVER the bare directory basename (R-ARCH-13). The home anchor resolves to the
# literal `home` catch-all (R-ARCH-14).
# Public functions (all print the resolved spoke key on stdout, diagnostics on
# stderr; non-zero exit = block):
#   spoke_registry_path            -> resolve the registry file path
#   spoke_resolve_from_cwd <cwd>   -> auto-resolve a spoke key (collision-safe)
#   spoke_validate_override <key>  -> validate a --project override against the registry
# Env overrides:
#   SPOKE_REGISTRY_PATH  registry file (test isolation). Else foundation governance/.
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

# Resolve the anchored-spoke registry path (test override -> foundation -> live).
spoke_registry_path() {
  if [[ -n "${SPOKE_REGISTRY_PATH:-}" ]]; then
    printf '%s\n' "$SPOKE_REGISTRY_PATH"
    return 0
  fi
  local here repo_root cand
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # skills/new-plan/lib -> repo root
  repo_root="$(cd "$here/../../.." 2>/dev/null && pwd)"
  for cand in \
    "${CLAUDE_HOME:-$HOME/.claude}/governance/anchored-spoke-registry.json" \
    "$repo_root/governance/anchored-spoke-registry.json"; do
    if [[ -f "$cand" ]]; then printf '%s\n' "$cand"; return 0; fi
  done
  printf '%s\n' "${CLAUDE_HOME:-$HOME/.claude}/governance/anchored-spoke-registry.json"
  return 0
}

# spoke_resolve_from_cwd <cwd> : print the resolved spoke key; non-zero on collision.
spoke_resolve_from_cwd() {
  local cwd="$1" reg
  reg="$(spoke_registry_path)"
  python3 - "$reg" "$cwd" "$HOME" <<'PY'
import json, os, sys
reg_path, cwd, home = sys.argv[1], sys.argv[2], sys.argv[3]

def fail(msg):
    print("spoke-resolve: %s" % msg, file=sys.stderr)
    sys.exit(1)

try:
    with open(reg_path, encoding="utf-8") as fh:
        reg = json.load(fh)
except Exception as exc:
    fail("cannot read anchored-spoke registry %s (%s)" % (reg_path, exc))

spokes = reg.get("spokes", [])

def expand(anchor):
    a = anchor.replace("$HOME", home)
    if a == "~":
        a = home
    elif a.startswith("~/"):
        a = os.path.join(home, a[2:])
    return os.path.normpath(a)

# Build anchor -> spoke_key map and detect cross-spoke collisions: the SAME
# normalized cwd anchor declared under two distinct spoke keys is a collision
# (R-ARCH-13: two distinct cwd anchors must not resolve to the same spoke key,
# and one anchor must not be claimed by two spoke keys).
anchor_owner = {}
for sp in spokes:
    key = sp.get("spoke_key", "")
    for raw in sp.get("cwd_anchors", []):
        norm = expand(raw)
        if norm in anchor_owner and anchor_owner[norm] != key:
            fail("collision: cwd anchor '%s' is claimed by spoke keys '%s' and '%s' — "
                 "resolve the anchored-spoke registry before creating plans"
                 % (norm, anchor_owner[norm], key))
        anchor_owner[norm] = key

cwd_norm = os.path.normpath(cwd)

# Longest-anchor-wins match (a deeper anchor beats a shallower one).
best_key, best_len = None, -1
home_key = None
for sp in spokes:
    key = sp.get("spoke_key", "")
    for raw in sp.get("cwd_anchors", []):
        norm = expand(raw)
        if norm == os.path.normpath(home):
            home_key = key
        if cwd_norm == norm or cwd_norm.startswith(norm.rstrip("/") + "/"):
            if len(norm) > best_len:
                best_key, best_len = key, len(norm)

if best_key is not None:
    print(best_key)
    sys.exit(0)

# No anchor matched -> the home catch-all (the literal "home" spoke key).
print(home_key or "home")
sys.exit(0)
PY
}

# spoke_validate_override <key> : print the key if it resolves to a registry
# entry; else block listing the valid keys (no silent fallback) — R-ARCH-14.
spoke_validate_override() {
  local key="$1" reg
  reg="$(spoke_registry_path)"
  python3 - "$reg" "$key" <<'PY'
import json, sys
reg_path, key = sys.argv[1], sys.argv[2]
try:
    with open(reg_path, encoding="utf-8") as fh:
        reg = json.load(fh)
except Exception as exc:
    print("spoke-resolve: cannot read anchored-spoke registry %s (%s)" % (reg_path, exc), file=sys.stderr)
    sys.exit(1)
keys = [sp.get("spoke_key", "") for sp in reg.get("spokes", [])]
if key in keys:
    print(key)
    sys.exit(0)
print("spoke-resolve: --project '%s' is not a registered spoke key. Valid keys: %s "
      "(no silent fallback — register the spoke or use a valid key)"
      % (key, ", ".join(sorted(k for k in keys if k))), file=sys.stderr)
sys.exit(1)
PY
}
