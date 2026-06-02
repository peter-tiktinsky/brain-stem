#!/usr/bin/env bash
# skills/onboarder/scripts/lib/settings-paths-probe.sh — read-only MCP-server probe.
#
# Reads MCP-server inventories from the THREE canonical settings paths Claude
# Code + Claude Desktop + Anthropic harness consult, dedups them, and emits a
# unified list. v2.0.0 Section A's `probe_mcp_keys_matching` only inspected
# `~/.claude/settings.json` — missed `~/.claude.json` (project-scoped) and
# `~/Library/Application Support/Claude/claude_desktop_config.json`. The wizard
# needs all 3 to compute the "already installed" badge per catalog entry.
#
# OUTPUT CONTRACT (R-43):
#   Files written: none — pure-read probe; emits to stdout
#   Schema-types: stdout is two-column TSV (one row per discovered server):
#     <server-id>\t<origin-path-tag>
#     where origin-path-tag is one of: settings | claude-json | desktop-config
#   Pre-write validation: not applicable (no writes)
#   Failure mode: BLOCK AND LOG only on hard errors. Missing path is
#                 non-fatal (skipped + logged); jq parse failure on a path
#                 is non-fatal (warning + skip).
#
# Usage:
#   bash skills/onboarder/scripts/lib/settings-paths-probe.sh [--dedup] [--list-paths]
#
# Flags:
#   --dedup        Emit deduplicated server-id list only (one column);
#                  default behavior is per-source TSV.
#   --list-paths   Emit the 3 canonical paths the probe inspects, then exit 0.
#                  Useful for smoke tests + diagnostic display.
#
# Path overrides (env vars; for synthetic test fixtures):
#   BRAIN_STEM_SETTINGS_PATH       (overrides ~/.claude/settings.json)
#   BRAIN_STEM_CLAUDE_JSON_PATH    (overrides ~/.claude.json)
#   BRAIN_STEM_DESKTOP_CONFIG_PATH (overrides ~/Library/Application Support/Claude/claude_desktop_config.json)
#
# Exit codes:
#   0  success (probe completes; missing paths are non-fatal)
#   2  bad invocation
#
# Dependencies: bash 3.2, jq, sort. R-37 single-deliverable.

set -u

_warn() { printf 'settings-paths-probe WARN: %s\n' "$1" >&2; }
_diag() { printf 'settings-paths-probe FAIL: %s\n' "$1" >&2; }

# --- canonical paths (with env-var overrides for test fixtures) ---
P_SETTINGS="${BRAIN_STEM_SETTINGS_PATH:-$HOME/.claude/settings.json}"
P_CLAUDE_JSON="${BRAIN_STEM_CLAUDE_JSON_PATH:-$HOME/.claude.json}"
P_DESKTOP_CONFIG="${BRAIN_STEM_DESKTOP_CONFIG_PATH:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"

# --- arg parse ---
mode="tsv"
list_paths=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dedup) mode="dedup"; shift ;;
    --list-paths) list_paths=1; shift ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional arg: $1"; exit 2 ;;
  esac
done

if [ "$list_paths" -eq 1 ]; then
  printf '%s\n' "$P_SETTINGS"
  printf '%s\n' "$P_CLAUDE_JSON"
  printf '%s\n' "$P_DESKTOP_CONFIG"
  exit 0
fi

# --- per-path extractor ---
# Reads .mcpServers keys from a JSON file. Missing file = log + skip.
# Parse failure = warn + skip. Each output line: <server-id>\t<tag>
extract_mcp_servers() {
  local path="$1"
  local tag="$2"
  if [ ! -r "$path" ]; then
    _warn "skip $tag — not readable: $path"
    return 0
  fi
  local keys
  keys=$(jq -r '.mcpServers // {} | keys[]' "$path" 2>/dev/null) || {
    _warn "skip $tag — jq parse failed: $path"
    return 0
  }
  if [ -z "$keys" ]; then
    return 0
  fi
  printf '%s\n' "$keys" | while IFS= read -r id; do
    [ -z "$id" ] && continue
    printf '%s\t%s\n' "$id" "$tag"
  done
}

# --- per-path probes ---
probe_all() {
  extract_mcp_servers "$P_SETTINGS" "settings"
  extract_mcp_servers "$P_CLAUDE_JSON" "claude-json"
  extract_mcp_servers "$P_DESKTOP_CONFIG" "desktop-config"
}

if [ "$mode" = "dedup" ]; then
  # Deduplicated server-id list (one column, sorted).
  probe_all | awk -F'\t' '{print $1}' | sort -u
else
  # Per-source TSV (server-id + origin tag); sorted for stable output.
  probe_all | sort -u
fi

exit 0
