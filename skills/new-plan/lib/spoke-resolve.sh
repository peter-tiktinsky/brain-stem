#!/bin/bash
# spoke-resolve.sh — cwd→spoke-key resolution against the anchored-spoke registry.
#
# Implements the collision-safe resolver and the --project
# override validation (surface-architecture). Sourced by the plan-creation
# writers (new-plan.sh, promote-from-inbox.sh); the resolution + collision +
# override logic lives in one place so both writers stay drift-resistant.
#
# The registry (governance/anchored-spoke-registry.json) maps cwd anchors to
# stable spoke keys. The stamped `project:` is the registry-resolved spoke key,
# NEVER the bare directory basename. The home anchor resolves to the
# literal `home` catch-all.
#
# Public functions (all print the resolved spoke key on stdout, diagnostics on
# stderr; non-zero exit = block):
#   spoke_registry_path            -> resolve the registry file path
#   spoke_resolve_from_cwd <cwd>   -> auto-resolve a spoke key (collision-safe)
#   spoke_validate_override <key>  -> validate a --project override against the registry
#
# Env overrides:
#   SPOKE_REGISTRY_PATH  registry file (test isolation). Else the $CLAUDE_HOME
#                        install, then the repo governance/ copy as a fallback.
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

# Resolve the anchored-spoke registry path through the ONE shared resolver
# (hooks/lib/anchored-spoke-registry.sh): test override -> the $CLAUDE_HOME
# install -> the repo governance/ copy. The live-install candidate is printed
# even when nothing exists on disk, so a caller reports the path it could not
# open. When the caller has declared a plan-tree write target, the pairing is
# coherence-checked first: a writer that stamps the live corpus from another
# tree's registry is blocked here, per this file's non-zero-exit-blocks contract.
spoke_registry_path() {
  local here repo_root plans_target
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # skills/new-plan/lib -> repo root
  repo_root="$(cd "$here/../../.." 2>/dev/null && pwd)"
  if ! command -v spoke_registry_resolve >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/anchored-spoke-registry.sh" 2>/dev/null \
      || source "$repo_root/hooks/lib/anchored-spoke-registry.sh" 2>/dev/null \
      || true
  fi
  if ! command -v spoke_registry_resolve >/dev/null 2>&1; then
    printf 'spoke-resolve: hooks/lib/anchored-spoke-registry.sh not found — cannot resolve the registry\n' >&2
    return 1
  fi
  local reg
  reg="$(spoke_registry_resolve_or_default "$repo_root/governance")"
  plans_target="${PLANS_ROOT:-${PLANS_DIR:-}}"
  if [[ -n "$plans_target" ]]; then
    spoke_registry_assert_coherent "$reg" "$plans_target" "spoke-resolve" || return 1
  fi
  printf '%s\n' "$reg"
  return 0
}

# spoke_resolve_from_cwd <cwd> : print the resolved spoke key; non-zero on collision.
spoke_resolve_from_cwd() {
  local cwd="$1" reg
  reg="$(spoke_registry_path)" || return 1
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
# (two distinct cwd anchors must not resolve to the same spoke key,
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

# --- anchor MATCHING normalization -------------------------------------------
# Two spellings of the SAME directory must resolve to the same spoke. Raw string
# comparison made that false twice over: a symlinked path missed its anchor, and on a
# case-insensitive filesystem `~/code/brain-stem` missed `~/Code/brain-stem` and fell
# through to the `home` catch-all — every downstream binder writer then took `home` as the
# active spoke. Both endpoints are therefore realpath-resolved before comparison, and
# compared case-folded when the filesystem says a case-variant spelling names the same
# object.
#
# The case decision is ASKED OF THE FILESYSTEM, never assumed from the platform: a
# case-variant spelling of the path is stat'ed and accepted only when it reports the same
# (st_dev, st_ino). os.path.normcase is identity on POSIX, so it cannot answer this on its
# own; and a hardcoded platform branch would fold a case-SENSITIVE volume, where /a/Foo and
# /a/foo are genuinely different directories, into one. A path that cannot be stat'ed (an
# anchor pointing at a dir that does not exist yet) answers "no" and is matched exactly, so
# the fold is never applied blind.
def resolved(p):
    try:
        return os.path.normpath(os.path.realpath(p))
    except Exception:
        return os.path.normpath(p)


_ci_cache = {}


def case_insensitive_fs(p):
    if p in _ci_cache:
        return _ci_cache[p]
    verdict = False
    leaf = os.path.basename(p)
    if leaf and leaf.swapcase() != leaf:
        variant = os.path.join(os.path.dirname(p), leaf.swapcase())
        try:
            a, b = os.stat(p), os.stat(variant)
            verdict = (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)
        except OSError:
            verdict = False
    _ci_cache[p] = verdict
    return verdict


cwd_norm = os.path.normpath(cwd)
cwd_res = resolved(cwd)
cwd_ci = case_insensitive_fs(cwd_res)

# Longest-anchor-wins match (a deeper anchor beats a shallower one).
best_key, best_len = None, -1
home_key = None
for sp in spokes:
    key = sp.get("spoke_key", "")
    for raw in sp.get("cwd_anchors", []):
        norm = expand(raw)
        if norm == os.path.normpath(home):
            home_key = key
        anchor_res = resolved(norm)
        fold = cwd_ci or case_insensitive_fs(anchor_res)
        a = anchor_res.lower() if fold else anchor_res
        c = cwd_res.lower() if fold else cwd_res
        if c == a or c.startswith(a.rstrip("/") + "/"):
            if len(anchor_res) > best_len:
                best_key, best_len = key, len(anchor_res)

if best_key is not None:
    print(best_key)
    sys.exit(0)

# No anchor matched -> the home catch-all (the literal "home" spoke key).
print(home_key or "home")
sys.exit(0)
PY
}

# spoke_validate_override <key> : print the key if it resolves to a registry
# entry; else block listing the valid keys (no silent fallback).
spoke_validate_override() {
  local key="$1" reg
  reg="$(spoke_registry_path)" || return 1
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
