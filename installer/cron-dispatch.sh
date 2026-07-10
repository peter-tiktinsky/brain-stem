#!/bin/bash
# installer/cron-dispatch.sh — GENERIC registry-driven cron_block dispatcher.
#
# The cron_block runtime-consumer the foundation lacked: capability-registry.json declares
# cron_block: {daily|weekly|monday} on ~20 capabilities with ZERO runtime consumers. This
# dispatcher ENUMERATES that roster (it is NOT hardcoded to one capability) so EVERY current +
# future cron_block declaration gets an execution owner — a render of the shipped launchd
# template/dispatch pattern (installer/render-launchd.sh + templates/launchd/). It emits a
# resolved dispatch PLAN (one SCHEDULE / DORMANT line per cron_block capability); a production
# `--install` mode would delegate each SCHEDULE entry to render-launchd.sh (launchctl-gated, not
# exercised here). It NEVER emits a launchd StandardOut/ErrorPath itself, so ship-gate sub-gate
# 12 (launchd TCC std-path guard) stays GREEN.
#
# DORMANT-UNTIL-OPT-IN activation (the ruling): writers-health-audit is DORMANT — it appears in
# the plan as DORMANT (never scheduled) — until BOTH (1) >= 1 vault writer is registered AND
# (2) the durable user-owned activation key is `enabled`:
#   behavioral.hook_preferences.writers_health_check  (user-manifest-schema.json:129-140 region;
#   tri-state: absent/"unset" = dormant/never-proposed, "enabled", "declined"). Read with
#   `jq // default`. The propose-and-confirm at first-writer registration
#   (skills/govern/modes/writer.sh mode_commit) flips it to enabled/declined.
#
# governance-parity-audit is DORMANT-UNTIL-OPT-IN too. It ships cron_block:weekly
# (capability-registry.json) but its 6 governance-PILLAR inputs are build-dogfood-only —
# unsatisfiable on an adopter install — so an unconditional weekly adopter schedule is
# incoherent. It is DORMANT unless
#   behavioral.hook_preferences.governance_parity_audit == "enabled".
# MANUAL opt-in: there is NO auto-propose event — governance-parity-audit is not
# writer-triggered (the writer.sh WRITER-HEALTH-PROPOSE is writer-registration-specific), the
# installer has no interactive opt-in surface, and no /govern mode is a governance-pillar
# registration event. The adopter opts in by SETTING THE KEY BY HAND (this dispatcher then honors
# it). Tri-state: absent/"unset" = dormant/never-proposed, "enabled" = scheduled weekly,
# "declined" = dormant + re-proposable.
#
# CLI:
#   cron-dispatch.sh                 # print the resolved dispatch plan (default)
#   cron-dispatch.sh --list          # (alias)
#   cron-dispatch.sh --help
#
# Env overrides (testing):
#   CRON_DISPATCH_REGISTRY   capability-registry.json (default: $CLAUDE_HOME/skills/librarian/…)
#   USER_MANIFEST_PATH       user-manifest.json (activation key source)
#   VAULT_ROOT               vault root (Vault Writers/ writer-count source)
#
# Bash 3.2 clean per R-23.
set -u

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"

MODE="list"
while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE="list"; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "cron-dispatch: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "cron-dispatch: jq required" >&2; exit 2; }

REGISTRY="${CRON_DISPATCH_REGISTRY:-}"
if [ -z "$REGISTRY" ]; then
  for cand in "$CLAUDE_HOME_RES/skills/librarian/capability-registry.json" \
              "$_REPO_ROOT/skills/librarian/capability-registry.json"; do
    [ -f "$cand" ] && { REGISTRY="$cand"; break; }
  done
fi
[ -f "$REGISTRY" ] || { echo "cron-dispatch: capability-registry.json not found" >&2; exit 2; }

USER_MANIFEST="${USER_MANIFEST_PATH:-$CLAUDE_HOME_RES/user-manifest.json}"

# --- resolve the writers-health activation key (tri-state; jq // default) -------
# absent / "unset" -> dormant (never proposed); "enabled" -> opt-in; "declined" -> dormant,
# re-proposable. additionalProperties:true on the block means the consumer reads with a default.
WH_KEY="unset"
if [ -f "$USER_MANIFEST" ]; then
  WH_KEY="$(jq -r '.behavioral.hook_preferences.writers_health_check // "unset"' "$USER_MANIFEST" 2>/dev/null || echo unset)"
  [ -n "$WH_KEY" ] && [ "$WH_KEY" != "null" ] || WH_KEY="unset"
fi

# --- resolve the governance-parity-audit activation key (tri-state; jq // default) ---
# absent / "unset" / "declined" -> dormant; "enabled" -> scheduled weekly. MANUAL opt-in:
# no auto-propose event; the adopter sets the key by hand. Mirrors WH_KEY above.
GP_KEY="unset"
if [ -f "$USER_MANIFEST" ]; then
  GP_KEY="$(jq -r '.behavioral.hook_preferences.governance_parity_audit // "unset"' "$USER_MANIFEST" 2>/dev/null || echo unset)"
  [ -n "$GP_KEY" ] && [ "$GP_KEY" != "null" ] || GP_KEY="unset"
fi

# --- writer count (dormant-until >=1 registered writer) ------------------------
WRITER_COUNT=0
if [ -n "${VAULT_ROOT:-}" ] && [ -d "$VAULT_ROOT/Vault Writers" ]; then
  for _w in "$VAULT_ROOT/Vault Writers"/*.md; do
    [ -f "$_w" ] || continue
    case "$(basename "$_w")" in _*) continue ;; esac
    WRITER_COUNT=$((WRITER_COUNT + 1))
  done
fi

# --- enumerate the cron_block roster + emit the dispatch plan -------------------
# Every capability with a schedulable cron_block (daily|weekly|monday) gets an owner. The
# skip-non-interactive class is NOT scheduled (session-close/librarian-full lane, by design).
jq -r '.capabilities | to_entries[]
        | select(.value.cron_block=="daily" or .value.cron_block=="weekly" or .value.cron_block=="monday")
        | "\(.key)\t\(.value.cron_block)"' "$REGISTRY" \
| sort \
| while IFS="$(printf '\t')" read -r cap block; do
    [ -n "$cap" ] || continue
    if [ "$cap" = "writers-health-audit" ]; then
      # DORMANT-UNTIL-OPT-IN: scheduled only when the adopter has opted in AND has >=1 writer.
      if [ "$WH_KEY" = "enabled" ] && [ "$WRITER_COUNT" -ge 1 ]; then
        printf 'SCHEDULE\t%s\t%s\n' "$cap" "$block"
      else
        _reason="activation=$WH_KEY writers=$WRITER_COUNT"
        printf 'DORMANT\t%s\t%s\t%s\n' "$cap" "$block" "$_reason"
      fi
      continue
    fi
    if [ "$cap" = "governance-parity-audit" ]; then
      # DORMANT-UNTIL-OPT-IN. Its governance-PILLAR
      # inputs are build-dogfood-only, so an adopter weekly schedule is incoherent: DORMANT unless
      # the durable activation key is `enabled` (MANUAL opt-in; no auto-propose event).
      if [ "$GP_KEY" = "enabled" ]; then
        printf 'SCHEDULE\t%s\t%s\n' "$cap" "$block"
      else
        printf 'DORMANT\t%s\t%s\t%s\n' "$cap" "$block" "activation=$GP_KEY"
      fi
      continue
    fi
    printf 'SCHEDULE\t%s\t%s\n' "$cap" "$block"
  done

exit 0
