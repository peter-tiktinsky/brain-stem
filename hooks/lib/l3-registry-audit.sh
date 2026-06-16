#!/bin/bash
# l3-registry-audit.sh — librarian capability (/81 T-10).
# Walks ~/Library/LaunchAgents/com.*.plist + ~/.claude/hooks/*.sh; maintains
# ~/.claude/hooks/lib/l3-writer-registry.json. Manifest-author-time lint
# flags Incident-β-class omissions: when a plan declares scope_paths
# overlapping a writer's write_paths AND the plan doesn't declare a pause
# (or carve-out exempt_paths) for that writer, surface a lint error.
# Weekly launchd cron registered to keep registry fresh.
# Subcommands:
#   walk [--plists-root <p>] [--hooks-root <p>] [--registry <p>]
#     Enumerate launchd plists matching com.*.plist + SessionEnd / hook scripts.
#     Surface drift findings: writers ON DISK but NOT in registry, AND
#     writers IN REGISTRY but ABSENT from disk.
#   lint <plan-id> [--registry <p>] [--plans-root <p>]
#     Cross-check a plan's manifest live_mutation_scope against registry.
#     Per registered writer, evaluate:
#       overlap = (writer's write_paths) ∩ (plan's scope_paths) - (plan's exempt_paths)
#       declared = (writer is in layer_3.session_end_hooks/launchd_labels/user_prompt_submit_writers)
#     If overlap is non-empty AND declared is false → Incident-β-class lint error.
#   summary [--registry <p>]
#     Dump current registry state: count of writers + post-tool-use advisories,
#     coverage by trigger type.
# Test-isolation env:
#   PLISTS_ROOT_OVERRIDE   - redirect launchd plist walk root
#   HOOKS_DIR_OVERRIDE     - redirect hook scripts walk dir
#   L3_REGISTRY_PATH       - registry file location
#   PLANS_ROOT_OVERRIDE    - plan-tree walk root (for lint)

set -uo pipefail

# layer it audits. Maintains hooks/lib/l3-writer-registry.json; consumed by
# hooks/lib/l3-pause-helper.sh. NOT registered in capability-registry.json
# (part of the 40-vs-44 drift closure). Install paths resolve via $CLAUDE_HOME.
_CH="${CLAUDE_HOME:-$HOME/.claude}"
DEFAULT_REGISTRY="$_CH/hooks/lib/l3-writer-registry.json"
DEFAULT_PLISTS="$HOME/Library/LaunchAgents"
DEFAULT_HOOKS="$_CH/hooks"
DEFAULT_PLANS_ROOT="${PLANS_DIR:-$HOME/.claude-plans}"

usage() {
  cat <<'EOF'
Usage: l3-registry-audit.sh <subcommand> [args]

Subcommands:
  walk [--plists-root <p>] [--hooks-root <p>] [--registry <p>]
  lint <plan-id> [--registry <p>] [--plans-root <p>]
  summary [--registry <p>]
EOF
  exit 2
}

[[ $# -lt 1 ]] && usage

SUBCMD="$1"; shift

# === Helper: normalize glob path for comparison ===========================
normalize_path() {
  local p="$1"
  p="${p//\$HOME/$HOME}"
  p="${p//\$VAULT_ROOT/${VAULT_ROOT:-$HOME/Documents/Obsidian Vault}}"
  p="${p//\$CLAUDE_HOME/${CLAUDE_HOME:-$HOME/.claude}}"
  # G5 (plan 110 T-63): the inline $HOOKS_STATE-token expansion default tracks the
  # new SoT default ($CLAUDE_STATE_ROOT/hooks-state, paths.sh:84) so the glob-overlap
  # normalize compares against the relocated root. This is a default-correction, not
  # a file read — a glob-string comparison takes no new-first/old-fallback probe.
  p="${p//\$HOOKS_STATE/${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}"
  p="${p%/\*\*}"
  p="${p%/\*}"
  printf '%s\n' "$p"
}

# === Helper: paths overlap (one is prefix of the other or equal) ==========
paths_overlap() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 0
  a="${a%/}"; b="${b%/}"
  [[ "$a" == "$b/"* ]] && return 0
  [[ "$b" == "$a/"* ]] && return 0
  return 1
}

# === Subcommand: walk =====================================================
cmd_walk() {
  local plists_root="${PLISTS_ROOT_OVERRIDE:-$DEFAULT_PLISTS}"
  local hooks_dir="${HOOKS_DIR_OVERRIDE:-$DEFAULT_HOOKS}"
  local registry="${L3_REGISTRY_PATH:-$DEFAULT_REGISTRY}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plists-root) plists_root="$2"; shift 2 ;;
      --hooks-root) hooks_dir="$2"; shift 2 ;;
      --registry) registry="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Enumerate on-disk launchd labels (filename without .plist suffix)
  local on_disk_plists='[]'
  if [[ -d "$plists_root" ]]; then
    for plist in "$plists_root"/com.*.plist; do
      [[ -e "$plist" ]] || continue
      local label
      label=$(basename "$plist" .plist)
      on_disk_plists=$(echo "$on_disk_plists" | jq -c --arg l "$label" '. + [$l]')
    done
  fi

  # Enumerate on-disk SessionEnd / hook scripts (best-effort: any *.sh under hooks dir)
  local on_disk_hooks='[]'
  if [[ -d "$hooks_dir" ]]; then
    while IFS= read -r hk; do
      [[ -z "$hk" ]] && continue
      local rel
      rel=$(basename "$hk")
      on_disk_hooks=$(echo "$on_disk_hooks" | jq -c --arg h "$rel" '. + [$h]')
    done < <(find "$hooks_dir" -maxdepth 2 -name "*.sh" -type f 2>/dev/null | sort)
  fi

  # Enumerate registered writers
  local registered_labels='[]' registered_hooks='[]'
  if [[ -r "$registry" ]]; then
    registered_labels=$(jq -c '[.writers[]? | select(.launchd_label) | .launchd_label]' "$registry" 2>/dev/null || echo '[]')
    registered_hooks=$(jq -c '[.writers[]? | select(.hook_path) | .hook_path | split("/") | last]' "$registry" 2>/dev/null || echo '[]')
  fi

  # Drift: on-disk labels NOT in registry
  local drift_unreg_labels
  drift_unreg_labels=$(jq -nc --argjson od "$on_disk_plists" --argjson reg "$registered_labels" \
    '$od - $reg' )

  # Drift: registered labels NOT on disk
  local drift_missing_labels
  drift_missing_labels=$(jq -nc --argjson od "$on_disk_plists" --argjson reg "$registered_labels" \
    '$reg - $od' )

  # Drift: on-disk hook scripts NOT registered (best-effort by basename)
  local drift_unreg_hooks
  drift_unreg_hooks=$(jq -nc --argjson od "$on_disk_hooks" --argjson reg "$registered_hooks" \
    '$od - $reg')

  # Emit JSON report
  jq -n \
    --argjson on_disk_plists "$on_disk_plists" \
    --argjson on_disk_hooks "$on_disk_hooks" \
    --argjson registered_labels "$registered_labels" \
    --argjson registered_hooks "$registered_hooks" \
    --argjson drift_unreg_labels "$drift_unreg_labels" \
    --argjson drift_missing_labels "$drift_missing_labels" \
    --argjson drift_unreg_hooks "$drift_unreg_hooks" \
    --arg registry "$registry" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
      ts: $ts, registry: $registry,
      on_disk: {plists: $on_disk_plists, hooks: $on_disk_hooks},
      registered: {labels: $registered_labels, hooks: $registered_hooks},
      drift: {
        unregistered_labels: $drift_unreg_labels,
        missing_labels_in_registry_only: $drift_missing_labels,
        unregistered_hooks: $drift_unreg_hooks
      }
    }'
}

# === Subcommand: lint ====================================================
cmd_lint() {
  local plan_id=""
  local registry="${L3_REGISTRY_PATH:-$DEFAULT_REGISTRY}"
  local plans_root="${PLANS_ROOT_OVERRIDE:-$DEFAULT_PLANS_ROOT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry) registry="$2"; shift 2 ;;
      --plans-root) plans_root="$2"; shift 2 ;;
      *)
        if [[ -z "$plan_id" ]]; then plan_id="$1"; fi
        shift ;;
    esac
  done

  [[ -z "$plan_id" ]] && { echo "lint: <plan-id> required" >&2; return 2; }

  local manifest="$plans_root/$plan_id/manifest.json"
  [[ -r "$manifest" ]] || { echo "lint: $manifest not found" >&2; return 2; }
  [[ -r "$registry" ]] || { echo "lint: $registry not found" >&2; return 2; }

  # Extract plan's scope_paths, exempt_paths, layer_3-declared writer ids
  local plan_lms
  plan_lms=$(jq -c '.live_mutation_scope // {}' "$manifest")
  local enabled
  enabled=$(echo "$plan_lms" | jq -r '.enabled // false')
  if [[ "$enabled" != "true" ]]; then
    echo "lint: $plan_id has live_mutation_scope.enabled != true; skipping" >&2
    jq -n --arg plan_id "$plan_id" '{plan_id: $plan_id, status: "skipped", findings: []}'
    return 0
  fi

  local scope_paths exempt_paths
  scope_paths=$(echo "$plan_lms" | jq -c '.scope_paths // []')
  exempt_paths=$(echo "$plan_lms" | jq -c '.exempt_paths // []')

  # Layer-3 declared writer IDs (best-effort matching)
  local declared_labels declared_session_end_paths declared_ups_patterns
  declared_labels=$(echo "$plan_lms" | jq -c '.layer_3.launchd_labels // []')
  declared_session_end_paths=$(echo "$plan_lms" | jq -c '[.layer_3.session_end_hooks[]?.path // empty]')
  declared_ups_patterns=$(echo "$plan_lms" | jq -c '[.layer_3.user_prompt_submit_writers[]?.path_pattern // empty]')

  # Walk registry writers
  local findings='[]'
  while IFS= read -r writer; do
    [[ -z "$writer" ]] && continue
    local wid wlabel wpath wmech wpaths
    wid=$(echo "$writer" | jq -r '.id // empty')
    wlabel=$(echo "$writer" | jq -r '.launchd_label // empty')
    wpath=$(echo "$writer" | jq -r '.hook_path // empty')
    wmech=$(echo "$writer" | jq -r '.pause_mechanism // empty')
    wpaths=$(echo "$writer" | jq -r '.write_paths[]?')

    [[ -z "$wpaths" ]] && continue

    # Check if any write_path overlaps any scope_path AND is NOT exempt'd
    local overlap_paths='[]'
    while IFS= read -r wp; do
      [[ -z "$wp" ]] && continue
      local wp_norm
      wp_norm=$(normalize_path "$wp")

      # Test overlap against any scope_path
      local in_scope=0
      while IFS= read -r sp; do
        [[ -z "$sp" ]] && continue
        local sp_norm
        sp_norm=$(normalize_path "$sp")
        if paths_overlap "$wp_norm" "$sp_norm"; then in_scope=1; break; fi
      done < <(echo "$scope_paths" | jq -r '.[]')

      [[ "$in_scope" == "0" ]] && continue

      # Check if exempt
      local is_exempt=0
      while IFS= read -r ep; do
        [[ -z "$ep" ]] && continue
        local ep_norm
        ep_norm=$(normalize_path "$ep")
        if paths_overlap "$wp_norm" "$ep_norm"; then is_exempt=1; break; fi
      done < <(echo "$exempt_paths" | jq -r '.[]')

      [[ "$is_exempt" == "1" ]] && continue

      overlap_paths=$(echo "$overlap_paths" | jq -c --arg p "$wp" '. + [$p]')
    done <<< "$wpaths"

    [[ "$(echo "$overlap_paths" | jq 'length')" == "0" ]] && continue

    # Writer's write_paths overlap plan scope and aren't exempt'd → must be declared
    local is_declared=0

    # Check by launchd_label
    if [[ -n "$wlabel" ]]; then
      if echo "$declared_labels" | jq -e --arg l "$wlabel" 'index($l) // null' >/dev/null 2>&1; then
        is_declared=1
      fi
    fi
    # Check by hook_path
    if [[ "$is_declared" == "0" && -n "$wpath" ]]; then
      if echo "$declared_session_end_paths" | jq -e --arg p "$wpath" 'index($p) // null' >/dev/null 2>&1; then
        is_declared=1
      fi
    fi

    if [[ "$is_declared" == "0" ]]; then
      # Incident-β-class finding: writer's write paths reach into the plan's
      # scope but plan declares neither a pause nor an exempt carve-out.
      local finding
      finding=$(jq -nc \
        --arg writer_id "$wid" \
        --arg writer_label "$wlabel" \
        --arg writer_hook "$wpath" \
        --arg writer_mechanism "$wmech" \
        --argjson overlap_paths "$overlap_paths" \
        '{writer_id: $writer_id, writer_label: $writer_label,
          writer_hook: $writer_hook, writer_mechanism: $writer_mechanism,
          overlap_paths: $overlap_paths,
          severity: "incident_beta_class"}')
      findings=$(echo "$findings" | jq -c --argjson f "$finding" '. + [$f]')
    fi
  done < <(jq -c '.writers[]?' "$registry")

  local count
  count=$(echo "$findings" | jq 'length')

  jq -n \
    --arg plan_id "$plan_id" \
    --argjson findings "$findings" \
    --argjson count "$count" \
    '{plan_id: $plan_id, status: (if $count > 0 then "lint_errors" else "clean" end),
      finding_count: $count, findings: $findings}'

  if [[ "$count" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# === Subcommand: summary ==================================================
cmd_summary() {
  local registry="${L3_REGISTRY_PATH:-$DEFAULT_REGISTRY}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry) registry="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ ! -r "$registry" ]]; then
    jq -n --arg p "$registry" '{registry_path: $p, exists: false}'
    return 0
  fi

  jq -n --slurpfile r "$registry" --arg p "$registry" '
    ($r[0]) as $reg
    | {
        registry_path: $p,
        exists: true,
        schema_version: ($reg.schema_version // null),
        regenerated_at: ($reg.regenerated_at // null),
        writer_counts: {
          total: ([$reg.writers[]?] | length),
          by_trigger: ([$reg.writers[]? | .trigger // "unknown"] | group_by(.) | map({trigger: .[0], count: length})),
          by_mechanism: ([$reg.writers[]? | .pause_mechanism // "unknown"] | group_by(.) | map({mechanism: .[0], count: length}))
        },
        post_tool_use_advisory_count: ([$reg._post_tool_use_advisory[]?] | length)
      }
  '
}

# === Dispatch =============================================================
case "$SUBCMD" in
  walk)    cmd_walk "$@" ;;
  lint)    cmd_lint "$@" ;;
  summary) cmd_summary "$@" ;;
  *)       usage ;;
esac
