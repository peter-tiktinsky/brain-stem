#!/usr/bin/env bash
# skills/onboarder/scripts/author-claude-home.sh — Tier-2 slim claude-home authoring.
#
# Authors $CLAUDE_HOME/CLAUDE.md from the slim claude-home template by consuming
# the slim user-manifest.json (schema 2.0.0). Uses the canonical substitution map,
# extended to inject the three behavioral prose
# blocks into the template's <USER: …> stubs.
#
# OUTPUT CONTRACT (R-43):
#   File written (atomic tmp+rename): $TARGET (default $CLAUDE_HOME/CLAUDE.md).
#   Schema-type: none (the rendered CLAUDE.md is prose, not a schema instance).
#   Pre-write validation: manifest + template readable; rendered output carries
#     zero {{[A-Z_]+}} residue.
#   Failure mode: BLOCK AND LOG. Any IO/render/residue failure exits non-zero;
#     the live target is never partially written (atomic rename). A pre-existing
#     target is NOT clobbered without --force (preserve user edits) — staged at
#     ${TARGET}.new with a diff, exit 2.
#
# Substitution:
#   - About Me line: {{IDENTITY_NAME}}, {{IDENTITY_ROLE}} at {{IDENTITY_ORGANIZATION}}.
#     assembled gracefully (role/org are voice-optional → null when independent;
#     no bare {{…}}, no dangling " at .").
#   - Prose injection: behavioral.{communication_style, working_patterns,
#     tooling_domain} → the matching `- <USER: …>` stub bullet. Null field leaves
#     the stub intact (hand-edit later). The About Me `<USER: 0-2 lines …>` stub
#     has no manifest source → left as-is.
#
# CONSTRAINTS (R-23): bash 3.2; jq + python3 required (python3 handles multi-line
#   prose substitution cleanly — established idiom from section-b-slim.sh).
#
# USAGE:
#   author-claude-home.sh [--user-manifest PATH] [--template PATH] [--target PATH]
#                         [--force] [--dry-run]
#
# Exit codes:
#   0   success | dry-run | skip-identical
#   2   bad invocation / missing dependency / target differs without --force
#   1   render / residue / IO failure (block-and-log)
#
set -u

diag() { printf 'author-claude-home FAIL: %s\n' "$1" >&2; }
info() { printf 'author-claude-home: %s\n' "$1" >&2; }

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# Self-contained skill: the shared CLAUDE.md template STAYS in its
# install-co-owned home; resolve it via $CLAUDE_HOME (no REPO_ROOT grandparent walk).
USER_MANIFEST="$CLAUDE_HOME/user-manifest.json"
TEMPLATE="$CLAUDE_HOME/templates/claude-home-claude-md-template.md"
TARGET="$CLAUDE_HOME/CLAUDE.md"
FORCE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user-manifest) USER_MANIFEST="$2"; shift 2 ;;
    --template)      TEMPLATE="$2"; shift 2 ;;
    --target)        TARGET="$2"; shift 2 ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       sed -n '2,46p' "$0"; exit 0 ;;
    *)               diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1      || { diag "jq required on PATH"; exit 2; }
command -v python3 >/dev/null 2>&1 || { diag "python3 required on PATH"; exit 2; }
[ -f "$TEMPLATE" ]      || { diag "template not found: $TEMPLATE"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }
jq -e . "$USER_MANIFEST" >/dev/null 2>&1 || { diag "user-manifest is not valid JSON: $USER_MANIFEST"; exit 2; }

# --- render via python3 (manifest + template -> stdout) ---
RENDERED="$(python3 - "$USER_MANIFEST" "$TEMPLATE" <<'PY'
import json, sys
manifest_path, template_path = sys.argv[1], sys.argv[2]
with open(manifest_path, encoding="utf-8") as f:
    m = json.load(f)
with open(template_path, encoding="utf-8") as f:
    text = f.read()

def g(path):
    cur = m
    for p in path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(p)
    if isinstance(cur, str):
        cur = cur.strip()
        return cur if cur else None
    return cur

name = g("identity.name") or "(unknown)"
role = g("identity.role")
org  = g("identity.organization")

# About Me line — assemble gracefully (role/org voice-optional → null).
if role and org:
    about = "%s, %s at %s." % (name, role, org)
elif role:
    about = "%s, %s." % (name, role)
elif org:
    about = "%s (%s)." % (name, org)
else:
    about = "%s." % name
# Normalize terminal punctuation: orgs ending in "." (Co./Inc./LLC.) must not
# yield a double period.
about = about.rstrip(".") + "."
text = text.replace(
    "{{IDENTITY_NAME}}, {{IDENTITY_ROLE}} at {{IDENTITY_ORGANIZATION}}.", about)
# Defensive: any standalone identity token (none expected beyond About Me).
text = text.replace("{{IDENTITY_NAME}}", name)
text = text.replace("{{IDENTITY_ROLE}}", role or "")
text = text.replace("{{IDENTITY_ORGANIZATION}}", org or "")

# Behavioral prose -> the matching <USER: …> stub bullet. Null leaves stub intact.
prose = {
    "- <USER: personal communication preferences>": g("behavioral.communication_style"),
    "- <USER: personal collaboration preferences>": g("behavioral.working_patterns"),
    "- <USER: cross-project tooling and domain context>": g("behavioral.tooling_domain"),
}
for stub, val in prose.items():
    if val:
        text = text.replace(stub, "- " + val)

sys.stdout.write(text)
PY
)" || { diag "python3 render failed"; exit 1; }

# --- residue assert (zero {{…}} residue) ---
RESIDUE="$(printf '%s' "$RENDERED" | grep -oE '\{\{[A-Z_]+\}\}' | sort -u)"
if [ -n "$RESIDUE" ]; then
  diag "residual placeholders after render: $(printf '%s' "$RESIDUE" | tr '\n' ' ')"
  exit 1
fi

# --- dry-run: diff + exit, zero mutations ---
if [ "$DRY_RUN" = "1" ]; then
  if [ -f "$TARGET" ]; then
    printf '%s\n' "$RENDERED" | diff -u "$TARGET" - >&2 \
      && echo "DRY-RUN: claude-home CLAUDE.md — no-op (byte-match) at $TARGET" >&2 \
      || echo "DRY-RUN: claude-home CLAUDE.md — would-update at $TARGET (diff above)" >&2
  else
    printf '%s\n' "$RENDERED" | diff -u /dev/null - >&2 || true
    echo "DRY-RUN: claude-home CLAUDE.md — would-create at $TARGET" >&2
  fi
  exit 0
fi

# --- no-clobber-without-force (preserve user edits) ---
if [ -f "$TARGET" ]; then
  if printf '%s\n' "$RENDERED" | cmp -s - "$TARGET"; then
    info "claude-home CLAUDE.md already up to date (byte-match) — no write"
    exit 0
  fi
  if [ "$FORCE" != "1" ]; then
    printf '%s\n' "$RENDERED" > "${TARGET}.new" || { diag "could not stage ${TARGET}.new"; exit 1; }
    echo "DIFF: claude-home CLAUDE.md differs at $TARGET (--force to overwrite). Staged at ${TARGET}.new" >&2
    printf '%s\n' "$RENDERED" | diff -u "$TARGET" - | head -60 >&2 || true
    exit 2
  fi
fi

# --- atomic tmp+rename ---
mkdir -p "$(dirname "$TARGET")" 2>/dev/null || { diag "cannot create target dir for $TARGET"; exit 1; }
TMP="${TARGET}.tmp.$$"
printf '%s\n' "$RENDERED" > "$TMP" || { rm -f "$TMP"; diag "stage to $TMP failed"; exit 1; }
mv "$TMP" "$TARGET" || { rm -f "$TMP"; diag "atomic rename to $TARGET failed"; exit 1; }
info "claude-home CLAUDE.md written to $TARGET"
exit 0
