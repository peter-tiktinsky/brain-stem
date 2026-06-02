#!/usr/bin/env bash
# verifier.sh — Post-dispatch filesystem verification for autonomous claude -p runs.
#
# Catches the "false success" failure mode: claude -p exits 0 but no actual
# work was committed. Empirical baseline (30-day audit at design time): 16%
# of dispatches reported status=success while producing zero commits across
# the watched repos. Dominant failure modes: sensitive-file-gate Edit no-ops
# (60%), empty-result sessions (20%), claimed-deliverable-but-no-file (20%).
#
# Source documentation:
#   - paperclipai/paperclip#1117 — public reference implementation of the
#     identical failure mode + fix stack (git-diff + result-text scan +
#     exit-code override).
#   - Replit Agent 3 self-test paper — validates that structural verification
#     beats exit-code scoring for "Potemkin" outputs.
#
# Two tiers:
#   Tier 1 (verdict-changing): Pre/post HEAD snapshot per watched repo.
#     Exit 0 with no HEAD advanced anywhere ⇒ FALSE-SUCCESS-NO-MUTATIONS.
#   Tier 2 (advisory): Result-text scan for blocked-phrases.
#     Exit 0 + work happened + warning phrase ⇒ PASS-WITH-WARNINGS.
#     (Doesn't change the verdict on its own — Tier 1 already catches the
#     case where blocked phrases co-occur with no mutations. Tier 2 surfaces
#     the case where SOME work landed but blocked phrases also appear,
#     suggesting partial completion.)
#
# Public functions:
#   verifier_default_repos          — newline-separated default watched-repo paths
#   verifier_snapshot_heads <repos> — read newline-separated repos from stdin,
#                                      emit JSON {"repos":[{"repo":"...",
#                                      "head":"<sha|null>","is_repo":true|false}]}
#   verifier_check <pre.json> <post.json> <result.txt>
#                                   — emit verification JSON with verdict field
#                                     return 0 if PASS or PASS-WITH-WARNINGS
#                                     return 1 if FALSE-SUCCESS-NO-MUTATIONS
#                                     return 2 if VERIFIER-ERROR (missing inputs)
#
# Constraints (R-23): bash 3.2.57 — no declare -A, no mapfile/readarray,
# no ${var,,}. jq required.

# --- Tier 2 blocked-phrase pattern ---
# Tightened to phrases tied to BLOCKED actions, not legitimate uses of "unable":
#   "unable to find" (legit) ⇒ NO match
#   "unable to write" (blocked) ⇒ MATCH
VERIFIER_BLOCKED_PATTERN='(I am |I'\''m )?(unable to|cannot) (proceed|edit|access|create|write|modify|save|commit)|permission (denied|blocked)|sensitive file|sensitive-file-gate|need[s]? approval|blocked by'

# --- Default watched repos ---
# Resolves from paths.sh-exported state (CLAUDE_HOME, PLANS_DIR, VAULT_ROOT).
# VAULT_ROOT may be empty (no install-convention default — graceful-degrade
# per paths.sh contract); skip-emit when so. Caller must have sourced
# paths.sh before invoking this helper.
verifier_default_repos() {
    [ -n "${CLAUDE_HOME:-}" ] && echo "$CLAUDE_HOME"
    [ -n "${PLANS_DIR:-}" ] && echo "$PLANS_DIR"
    [ -n "${VAULT_ROOT:-}" ] && echo "$VAULT_ROOT"
}

# --- Snapshot HEADs ---
# Reads newline-separated repo paths from stdin.
# Emits: {"repos":[{"repo":"<path>","head":"<sha>"|null,"is_repo":true|false}, ...]}
# Exit 0 always (missing repos are recorded, not errors).
verifier_snapshot_heads() {
    local entries='[]'
    local repo head is_repo head_json
    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        is_repo="false"
        head_json="null"
        if [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; then
            is_repo="true"
            head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
            if [ -n "$head" ]; then
                head_json=$(jq -nc --arg h "$head" '$h')
            fi
        fi
        entries=$(echo "$entries" | jq \
            --arg repo "$repo" \
            --argjson head "$head_json" \
            --argjson is_repo "$is_repo" \
            '. + [{"repo": $repo, "head": $head, "is_repo": $is_repo}]')
    done
    jq -n --argjson r "$entries" '{repos: $r}'
}

# --- Verifier core ---
# Args: <pre-snapshot-json-file> <post-snapshot-json-file> <result-text-file>
# Emits verification JSON to stdout with these fields:
#   head_advances: [{repo, before, after, advanced, new_commits}, ...]
#   any_advanced: bool
#   result_text_warnings: ["<matched-phrase>", ...]
#   verdict: "PASS" | "PASS-WITH-WARNINGS" | "FALSE-SUCCESS-NO-MUTATIONS" | "VERIFIER-ERROR"
# Exit code: 0 (PASS or PASS-WITH-WARNINGS), 1 (FALSE-SUCCESS), 2 (verifier error)
verifier_check() {
    local pre_file="$1" post_file="$2" result_file="$3"

    if [ ! -f "$pre_file" ]; then
        jq -n --arg msg "pre-snapshot missing: $pre_file" '{verdict:"VERIFIER-ERROR", error:$msg}'
        return 2
    fi
    if [ ! -f "$post_file" ]; then
        jq -n --arg msg "post-snapshot missing: $post_file" '{verdict:"VERIFIER-ERROR", error:$msg}'
        return 2
    fi

    # --- Tier 1: per-repo HEAD advance check ---
    # Pre/post lists are aligned by index (same watched-repos list, snapshot
    # twice in same process). Compute advances + count new commits per repo.
    local advances
    advances=$(jq -n \
        --slurpfile pre "$pre_file" \
        --slurpfile post "$post_file" \
        '
        ($pre[0].repos // []) as $p
        | ($post[0].repos // []) as $q
        | [range(0; ($p | length)) as $i
           | {
               repo: $p[$i].repo,
               is_repo: $p[$i].is_repo,
               before: $p[$i].head,
               after: ($q[$i].head // null),
               advanced: (
                   ($p[$i].is_repo == true)
                   and (($q[$i] // {}).is_repo == true)
                   and ($p[$i].head != null)
                   and (($q[$i] // {}).head != null)
                   and ($p[$i].head != ($q[$i] // {}).head)
               )
             }
          ]
        ')

    # Count new commits per repo using rev-list (only for advanced repos)
    local advances_with_counts='[]'
    local repo before after advanced new_commits
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        repo=$(echo "$entry" | jq -r '.repo')
        before=$(echo "$entry" | jq -r '.before // empty')
        after=$(echo "$entry" | jq -r '.after // empty')
        advanced=$(echo "$entry" | jq -r '.advanced')
        new_commits=0
        if [ "$advanced" = "true" ] && [ -n "$before" ] && [ -n "$after" ] && [ -d "$repo/.git" ]; then
            new_commits=$(git -C "$repo" rev-list --count "${before}..${after}" 2>/dev/null || echo "0")
        fi
        advances_with_counts=$(echo "$advances_with_counts" | jq \
            --argjson e "$entry" \
            --argjson nc "$new_commits" \
            '. + [($e + {new_commits: $nc})]')
    done < <(echo "$advances" | jq -c '.[]')

    local any_advanced
    any_advanced=$(echo "$advances_with_counts" | jq 'any(.advanced)')

    # --- Tier 2: result-text scan ---
    local warnings='[]'
    if [ -f "$result_file" ] && [ -s "$result_file" ]; then
        local matches
        matches=$(grep -ioE "$VERIFIER_BLOCKED_PATTERN" "$result_file" 2>/dev/null | sort -u | head -10)
        if [ -n "$matches" ]; then
            warnings=$(printf '%s\n' "$matches" | jq -R -s 'split("\n") | map(select(. != ""))')
        fi
    fi

    # --- Verdict ---
    local verdict warning_count
    warning_count=$(echo "$warnings" | jq 'length')
    if [ "$any_advanced" = "true" ]; then
        if [ "$warning_count" -gt 0 ]; then
            verdict="PASS-WITH-WARNINGS"
        else
            verdict="PASS"
        fi
    else
        verdict="FALSE-SUCCESS-NO-MUTATIONS"
    fi

    # --- Emit verification JSON ---
    jq -n \
        --argjson advances "$advances_with_counts" \
        --argjson any_advanced "$any_advanced" \
        --argjson warnings "$warnings" \
        --arg verdict "$verdict" \
        '{
            head_advances: $advances,
            any_advanced: $any_advanced,
            result_text_warnings: $warnings,
            verdict: $verdict
        }'

    case "$verdict" in
        PASS|PASS-WITH-WARNINGS) return 0 ;;
        FALSE-SUCCESS-NO-MUTATIONS) return 1 ;;
        *) return 2 ;;
    esac
}
