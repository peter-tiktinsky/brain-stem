#!/bin/bash
# managed-surface-census — hash every live foundation-manifest files[] member
# against its recorded sha256 and surface any divergence as an NDJSON finding.
#
# THE CLOSING LAYER for the live-only-fork defect class. The write-time
# managed-surface arm in pre-write-guard.sh sees only Edit/Write tool calls —
# shell, cron and capability writes structurally bypass PreToolUse (the matcher
# is Edit|Write by ruled design). This census catches EVERY vector: it walks
# the live foundation-manifest files[] (path + recorded sha256 — the delivery
# baseline already on disk) and compares live bytes. It fills exactly the slot
# sanctioned-schema-drift-detect.sh names out of its own scope ("a live-hash vs
# manifest-recorded-hash mechanism") and duplicates none of that detector's
# live-vs-source scope; unlike that build-dogfood check it needs NO foundation
# repo, so it runs identically on an adopter install.
#
# DERIVE-clean: detect-never-autofix. The census never writes to any scanned
# file — its only writes are the finding stream (findings.sh: FINDINGS_OUTPUT
# or stdout) and its own tripwire snapshot under $CLAUDE_STATE_ROOT/census/.
#
# TRIPWIRE, not a static scan: a divergence emits a loud finding only the first
# run it is seen (compared against the previous run's snapshot); a persisting
# known divergence is counted in the summary line instead of re-emitted, so the
# stream never trains the reader to skip it. The snapshot is state, not a
# baseline — the manifest sha is always the comparison authority.
#
# CLASSIFIED, NOT FLAGGED (two lanes that are never fork findings):
#   - governance/overlay-master.json — the adopter-extension surface, the SOLE
#     files[] member a sanctioned runtime writer mutates (the locked
#     overlay-master-mutate.sh path). Divergence there is expected state.
#   - *.foundation-retired / *.foundation-local sidecars — installer/upgrade
#     retirement artifacts and adopter-local variants; non-members by
#     construction, surfaced informationally under the sidecar class.
#
# Finding shapes (hooks/lib/findings.sh contract):
#   {"finding":"managed-surface-fork","file":<abs>,"class":"modified|missing",
#    "expected_sha":<sha>,"actual_sha":<sha|absent>}
#   {"finding":"managed-surface-classified","file":<abs>,"class":"adopter-owned|sidecar"}
#
# Usage:
#   managed-surface-census.sh            # walk, emit new findings, update snapshot
#   managed-surface-census.sh --full     # re-emit ALL current divergences (no tripwire dedup)
#   managed-surface-census.sh --help
#
# Env:
#   CLAUDE_HOME         live install root (default $HOME/.claude)
#   CENSUS_STATE_DIR    snapshot home (default $CLAUDE_STATE_ROOT/census)
#   FINDINGS_OUTPUT     findings.sh routing (append file; default stdout)
#
# Exit codes: 0 = clean or classified-only; 1 = fork finding(s) present this
# run (block-and-log); 2 = usage error. An absent/unreadable live
# foundation-manifest CLEAN-SKIPS (rc 0) — a content census, not access
# control, degrades open.
#
# Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${CLAUDE_STATE_ROOT:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"

FULL="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL="true"; shift ;;
    -h|--help) sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "managed-surface-census: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

MANIFEST="$CLAUDE_HOME_RES/governance/foundation-manifest.json"
if [[ ! -f "$MANIFEST" ]] || ! jq -e '.files' "$MANIFEST" >/dev/null 2>&1; then
  echo "managed-surface-census: no readable foundation-manifest at $MANIFEST — clean skip (nothing to census)"
  exit 0
fi

STATE_DIR="${CENSUS_STATE_DIR:-${CLAUDE_STATE_ROOT}/census}"
SNAPSHOT="$STATE_DIR/managed-surface.snapshot"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# The sole files[] member a sanctioned runtime writer mutates (the locked
# overlay-master-mutate.sh path) — expected divergence, adopter-owned class.
ADOPTER_OWNED_REL="governance/overlay-master.json"

# One python pass computes every divergence line: "<class>\t<rel>\t<expected>\t<actual>".
# Data reaches python via argv, never a piped stdin.
DIVERGENCES=$(python3 - "$MANIFEST" "$CLAUDE_HOME_RES" <<'PYEOF'
import hashlib, json, os, sys

manifest_path, live_root = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    manifest = json.load(f)

for entry in manifest.get("files", []):
    rel = entry.get("path", "")
    expected = entry.get("sha256", "")
    if not rel or not expected:
        continue
    live = os.path.join(live_root, rel)
    if not os.path.isfile(live):
        print("missing\t%s\t%s\tabsent" % (rel, expected))
        continue
    h = hashlib.sha256()
    with open(live, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    actual = h.hexdigest()
    if actual != expected:
        print("modified\t%s\t%s\t%s" % (rel, expected, actual))
PYEOF
) || { echo "managed-surface-census: manifest walk failed" >&2; exit 2; }

# Sidecar sweep: retirement/local artifacts under the managed top-level dirs
# (suffix grammar, not a membership scan — runtime non-member files are legion
# and are not this census's concern).
MANAGED_TOPS=$(jq -r '[.files[]?.path | split("/")[0]] | unique | .[]' "$MANIFEST" 2>/dev/null | grep -v '^\.' || true)
SIDECARS=""
for top in $MANAGED_TOPS; do
  [[ -d "$CLAUDE_HOME_RES/$top" ]] || continue
  found=$(find "$CLAUDE_HOME_RES/$top" \( -name '*.foundation-retired' -o -name '*.foundation-local' \) -type f 2>/dev/null || true)
  [[ -n "$found" ]] && SIDECARS="${SIDECARS}${found}"$'\n'
done

PREV=""
[[ -f "$SNAPSHOT" ]] && PREV=$(cat "$SNAPSHOT" 2>/dev/null || true)
NEW_SNAPSHOT=""
FORK_COUNT=0
NEW_FORK_COUNT=0
CLASSIFIED_COUNT=0

emit_fork() {  # $1=class $2=rel $3=expected $4=actual
  emit_finding "managed-surface-fork" "$CLAUDE_HOME_RES/$2" \
    "class" "$1" "expected_sha" "$3" "actual_sha" "$4"
}

while IFS=$'\t' read -r dclass drel dexp dact; do
  [[ -z "${drel:-}" ]] && continue
  if [[ "$drel" == "$ADOPTER_OWNED_REL" ]]; then
    key="classified|adopter-owned|$drel"
    NEW_SNAPSHOT="${NEW_SNAPSHOT}${key}"$'\n'
    CLASSIFIED_COUNT=$((CLASSIFIED_COUNT + 1))
    if [[ "$FULL" == "true" ]] || ! printf '%s' "$PREV" | grep -Fqx "$key"; then
      emit_finding "managed-surface-classified" "$CLAUDE_HOME_RES/$drel" "class" "adopter-owned"
    fi
    continue
  fi
  key="fork|$dclass|$drel|$dact"
  NEW_SNAPSHOT="${NEW_SNAPSHOT}${key}"$'\n'
  FORK_COUNT=$((FORK_COUNT + 1))
  if [[ "$FULL" == "true" ]] || ! printf '%s' "$PREV" | grep -Fqx "$key"; then
    NEW_FORK_COUNT=$((NEW_FORK_COUNT + 1))
    emit_fork "$dclass" "$drel" "$dexp" "$dact"
  fi
done <<EOF
$DIVERGENCES
EOF

while IFS= read -r sc; do
  [[ -z "$sc" ]] && continue
  key="classified|sidecar|$sc"
  NEW_SNAPSHOT="${NEW_SNAPSHOT}${key}"$'\n'
  CLASSIFIED_COUNT=$((CLASSIFIED_COUNT + 1))
  if [[ "$FULL" == "true" ]] || ! printf '%s' "$PREV" | grep -Fqx "$key"; then
    emit_finding "managed-surface-classified" "$sc" "class" "sidecar"
  fi
done <<EOF
$SIDECARS
EOF

printf '%s' "$NEW_SNAPSHOT" > "$SNAPSHOT" 2>/dev/null || true

TOTAL=$(jq -r '.files | length' "$MANIFEST" 2>/dev/null || echo "?")
echo "managed-surface-census: $TOTAL members walked; $FORK_COUNT fork divergence(s) ($NEW_FORK_COUNT new this run); $CLASSIFIED_COUNT classified (adopter-owned/sidecar)"
[[ "$FORK_COUNT" -gt 0 ]] && exit 1
exit 0
