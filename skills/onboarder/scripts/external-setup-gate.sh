#!/usr/bin/env bash
# skills/onboarder/scripts/external-setup-gate.sh — (Tier-2 external-setup soft-mandate gate).
#
# Soft-mandate gate over the two GA external dependencies — claude-mem + GitHub.
# (Obsidian moved OUT to the build-brain-vault Step-5 vault-open confirm beat per
# .) For each: probe (read-only) whether it is already set up; if not,
# present a strong recommendation + honest rationale + frictionless skip; record
# the disposition. A soft mandate: strong rec + frictionless
# skip + honest cost framing — the flow completes coherently whether the user sets
# up both or neither. NEVER blocks.
#
# The clean Tier-2 successor to the Tier-3 connector wizard (mcp-registry-probe.sh +
# connectors/wizard.sh — registry enumeration + 80-tool cap, out of scope).
# Reuses only the clean read-only settings-paths-probe.sh for claude-mem detection.
#
# OUTPUT CONTRACT (R-43):
#   File written (atomic tmp+rename):
#     $CLAUDE_HOME/onboarding/external-setup-state.json
#       { "<tool>": { "status": "present|pending|skipped", "ts": "<iso8601>" }, ... }
#   Audit (append-only JSONL): $CLAUDE_HOME/onboarding/audit/external-setup-gate.jsonl
#     Structural metadata only (run_id, ts, tool, status) — never user strings.
#   Pre-write validation: jq present; CLAUDE_HOME resolvable.
#   Failure mode: BLOCK AND LOG on IO error only. Probes that error degrade to
#     "absent" (never crash the gate). The gate itself never blocks the flow.
#
# Probes (read-only):
#   claude-mem: a claude-mem registry entry in
#               $CLAUDE_HOME/plugins/installed_plugins.json (the file Claude Code
#               itself reads to load plugins — the SDK-only `npm i -g` footgun never
#               writes it). Shape-robust: .plugins may be an OBJECT keyed by
#               <plugin>@<marketplace> (→ keys) or an ARRAY of strings (→ elements);
#               a missing/unreadable file ⇒ non-present. Cross-checked against a
#               claude[-_]mem server in settings-paths-probe.sh --dedup.
#   github:     `gh` on PATH AND `gh auth status` rc=0.
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   external-setup-gate.sh [--state PATH] [--audit-log PATH] [--auto-accept]
#                          [--auto-skip] [--probe-lib PATH]
#
# Env knobs (tests + non-interactive):
#   AUTO_ACCEPT=1   accept all recommendations as `pending` (non-interactive)
#   AUTO_SKIP=1     skip all recommendations as `skipped` (non-interactive)
#   SETUP_CLAUDE_MEM / SETUP_GH = present|absent
#                   force a probe result (hermetic tests)
#
# Exit codes: 0 always (soft-mandate — never blocks) | 2 bad invocation/dep
#             | 1 IO/state-write failure (block-and-log)
#
# Author: Claude Opus 4.7 (1M context) —
set -u

diag() { printf 'external-setup-gate FAIL: %s\n' "$1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

STATE="$CLAUDE_HOME/onboarding/external-setup-state.json"
AUDIT_LOG="$CLAUDE_HOME/onboarding/audit/external-setup-gate.jsonl"
PROBE_LIB="$SCRIPT_DIR/lib/settings-paths-probe.sh"
AUTO_ACCEPT="${AUTO_ACCEPT:-0}"
AUTO_SKIP="${AUTO_SKIP:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --state)        STATE="$2"; shift 2 ;;
    --audit-log)    AUDIT_LOG="$2"; shift 2 ;;
    --probe-lib)    PROBE_LIB="$2"; shift 2 ;;
    --auto-accept)  AUTO_ACCEPT=1; shift ;;
    --auto-skip)    AUTO_SKIP=1; shift ;;
    -h|--help)      sed -n '2,52p' "$0"; exit 0 ;;
    *)              diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { diag "jq required on PATH"; exit 2; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$(dirname "$STATE")" "$(dirname "$AUDIT_LOG")" 2>/dev/null \
  || { diag "cannot create output directories"; exit 1; }

# Seed state from prior run if present (idempotent re-run preserves dispositions).
STATE_JSON='{}'
[ -f "$STATE" ] && STATE_JSON="$(jq -c . "$STATE" 2>/dev/null || echo '{}')"

audit() {
  # $1=tool $2=status — structural only.
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg run "$RUN_ID" \
    --arg tool "$1" --arg status "$2" \
    '{ts:$ts, run_id:$run, tool:$tool, status:$status}' >> "$AUDIT_LOG" 2>/dev/null || true
}

record() {
  # $1=tool $2=status — update in-memory state JSON (flushed atomically at end).
  STATE_JSON="$(printf '%s' "$STATE_JSON" | jq -c --arg t "$1" --arg s "$2" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.[$t] = {status:$s, ts:$ts}')"
  audit "$1" "$2"
}

# --- probes (read-only; SETUP_* override wins for hermetic tests) ---
probe_claude_mem() {
  case "${SETUP_CLAUDE_MEM:-}" in present) return 0 ;; absent) return 1 ;; esac
  # registry-truth check. The old `plugins/*claude-mem*` glob
  # and bare `command -v claude-mem` rungs false-positived — `npm install -g
  # claude-mem` leaves the SDK binary on PATH WITHOUT registering hooks (upstream's
  # own footgun), and install.sh never creates plugins/. Read the registry
  # Claude Code itself loads plugins from. Shape-robust: .plugins may be an OBJECT
  # keyed by <plugin>@<marketplace> (→ keys) or an ARRAY of strings (→ elements);
  # match startswith("claude-mem@") or =="claude-mem". Missing/unreadable file ⇒
  # non-present (degrade to offering the recommendation; gate never blocks).
  local reg="$CLAUDE_HOME/plugins/installed_plugins.json"
  if [ -r "$reg" ]; then
    jq -e '
      (.plugins // empty)
      | (if type == "object" then keys
         elif type == "array" then .
         else [] end)
      | map(select(type == "string"
              and (startswith("claude-mem@") or . == "claude-mem")))
      | length > 0
    ' "$reg" >/dev/null 2>&1 && return 0
  fi
  if [ -r "$PROBE_LIB" ]; then
    bash "$PROBE_LIB" --dedup 2>/dev/null | grep -qiE 'claude[-_]?mem' && return 0
  fi
  return 1
}
probe_github() {
  case "${SETUP_GH:-}" in present) return 0 ;; absent) return 1 ;; esac
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  # a user who ran `gh auth login` but never `gh auth setup-git` passes
  # the checks above yet cannot push (git's HTTPS credential helper is unset).
  # Require the HTTPS credential helper for github.com to resolve (any-scope —
  # backup.sh resolves any-scope helpers). A missing helper degrades safely to
  # offering the recommendation (the gate never blocks; exit 0 preserved).
  git config --get-regexp '^credential\.https://github\.com\.helper$' >/dev/null 2>&1
}

# --- recommendation copy (honest cost framing) ---
recommend() {
  # $1=tool $2=title $3=rationale $4=how-to
  cat >&2 <<EOF

  ── $2 — strongly recommended ───────────────────────────
  $3
  How:  $4
  (You can skip and set this up later — the rest of your setup still works.)
EOF
}

# --- post-acceptance reconcile (kill sticky-pending) ---
reconcile_accept() {
  # $1=tool-key $2=probe-fn — re-probe after the user accepts so an accepted
  # offer reconciles to a verified terminal state: a successful same-run install
  # flips pending->present; a failed one stays honestly `pending` and self-heals
  # on a later re-run via the :127 probe short-circuit + the :78-80 prior-state
  # seed. In-enum value flip only (present|pending|skipped preserved).
  if "$2"; then
    record "$1" "present"; printf '    → recorded: present (verified)\n' >&2
  else
    record "$1" "pending"; printf '    → recorded: will set up\n' >&2
  fi
}

# --- gate one tool ---
gate_tool() {
  # $1=tool-key $2=probe-fn $3=title $4=rationale $5=how-to
  if "$2"; then
    printf '  ✓ %s — already set up.\n' "$3" >&2
    record "$1" "present"
    return 0
  fi
  recommend "$1" "$3" "$4" "$5"
  if [ "$AUTO_SKIP" = "1" ]; then
    record "$1" "skipped";  printf '    → recorded: skipped\n' >&2; return 0
  fi
  if [ "$AUTO_ACCEPT" = "1" ]; then
    reconcile_accept "$1" "$2"; return 0
  fi
  printf '    Set this up now? [Y]es / [s]kip > ' >&2
  if ! IFS= read -r ans; then ans="s"; fi
  case "$ans" in
    s|S|skip) record "$1" "skipped" ;;
    *)        reconcile_accept "$1" "$2" ;;
  esac
}

printf '\n=== External setup — recommended for the full experience ===\n' >&2

# claude-mem onboarding offer (.2). claude-mem
# is OPTIONAL/recommended, NEVER required (System B is strictly additive). Honest
# standalone-vs-augmented framing + the concrete marketplace-install command.
gate_tool claude-mem probe_claude_mem "claude-mem (memory)" \
  "brain-stem's curated memory works standalone; claude-mem adds automatic wide-net recall on top. It's an optional, recommended marketplace plugin — your memory system is fully functional without it." \
  "Run: npx claude-mem install   (optional — skip and your curated memory still works)."

gate_tool github probe_github "GitHub (backup)" \
  "To back up your vault (full version history) and protect your Claude setup — recover from any mistake, sync across machines." \
  "Run these in order:
          brew install gh                 (install the GitHub CLI first if needed)
          gh auth login                   (authenticate the CLI)
          gh auth setup-git               (wire git's HTTPS credential helper — required so backup pushes work)
          gh repo create <name> --private --source \"\$VAULT_ROOT\" --remote origin --push   (optional — provision the backup remote)"

# --- atomic flush of state ---
TMP="${STATE}.tmp.$$"
printf '%s\n' "$STATE_JSON" | jq . > "$TMP" 2>/dev/null || { rm -f "$TMP"; diag "state render failed"; exit 1; }
mv "$TMP" "$STATE" || { rm -f "$TMP"; diag "atomic rename to $STATE failed"; exit 1; }

printf '\nExternal-setup dispositions recorded at %s\n' "$STATE" >&2
exit 0
