#!/usr/bin/env bash
# modes/doc-amender-prompt.sh — Layer-3 prompt-authoring mode for the
# doc-amender (the 5th /govern register registration class).
#
# T-04 (B2 Layer-3 — NET-NEW). The doc-amender RUNTIME
# (skills/doc-amender/process.sh) is disable-model-invocation:true; this mode is
# its MODEL-INVOCABLE create-time companion. The two are connected ONLY by the
# contract file (governance/file-type-contracts/doc-amender-prompt.md.json).
#
# The guided flow (5 steps; the system proposes, the operator reviews and
# accepts — propose-and-confirm, never auto-apply):
#   (i)   take a target destination + the set of upstream writers;
#   (ii)  interview the operator on per-destination merge intent — the
#         merge-intent taxonomy maps to amendment_strategy
#         {append-section, template-fill, prompt-guided-amend} + persistence_mode
#         {deterministic, llm-mediated, hybrid} (from the T-05 contract);
#   (iii) render a contract-compliant prompt asset (frontmatter per
#         doc-amender-prompt.md.json + a body);
#   (iv)  validate against doc-amender-prompt.md.json BEFORE write
#         (block-and-log; never write-and-hope);
#   (v)   write create-only to $VAULT_WRITER_STATE_ROOT/prompts/<prompt_id>.md;
#   (vi)  optionally create/extend the writer-fan-in entry in
#         governance/doc-dependencies.json.
#
# OUTPUT CONTRACT (Skill Creation Rules — MANDATORY):
#   Files written:
#     1. $VAULT_WRITER_STATE_ROOT/prompts/<prompt_id>.md (the prompt asset;
#        CREATE-ONLY — refuses to clobber an existing prompt; atomic temp+rename).
#     2. (optional, --with-fan-in) a writer-fan-in entry appended to
#        governance/doc-dependencies.json :: entries[] (1 consumer glob +
#        N upstream_writers[]); also create-only on the entry id.
#   Schema type: doc-amender-prompt (governance/file-type-contracts/
#     doc-amender-prompt.md.json — validated BEFORE write).
#   Pre-write validation: contract conformance (frontmatter_required present;
#     frontmatter_enums honored; amendment_strategy ↔ persistence_mode mapping
#     consistent) BEFORE the create-only write.
#   Failure mode: BLOCK-AND-LOG — any validation failure / existing-file
#     collision / invalid enum returns non-zero with a diagnostic; nothing is
#     written. Never write-and-hope.
#
# Sourced by process.sh. Exposes mode_propose() and mode_commit().
# bash 3.2 compatible. jq REQUIRED. python3 used for YAML render (mirrors writer.sh).

# Resolve the contract path (installed layout wins; repo fallback for tests).
_dap_contract_path() {
  local ch="${CLAUDE_HOME:-$HOME/.claude}"
  if [ -r "$ch/governance/file-type-contracts/doc-amender-prompt.md.json" ]; then
    printf '%s' "$ch/governance/file-type-contracts/doc-amender-prompt.md.json"
  elif [ -n "${GOVERN_REPO_ROOT:-}" ] && [ -r "$GOVERN_REPO_ROOT/governance/file-type-contracts/doc-amender-prompt.md.json" ]; then
    printf '%s' "$GOVERN_REPO_ROOT/governance/file-type-contracts/doc-amender-prompt.md.json"
  else
    # Last resort: derive from this mode handler's location (skills/govern/modes/).
    local self_dir
    self_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
    printf '%s' "$self_dir/../../../governance/file-type-contracts/doc-amender-prompt.md.json"
  fi
}

# Resolve the prompts root (state-tier, outside-vault).
_dap_prompts_root() {
  local vwsr="${VAULT_WRITER_STATE_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/brain-stem/vault-writers}"
  printf '%s/prompts' "$vwsr"
}

# Map a merge-intent value to (amendment_strategy, persistence_mode) per the
# T-05 contract pattern_menu. Echoes "<strategy>\t<persistence_mode>".
_dap_intent_to_strategy() {
  case "$1" in
    table-upsert|action-items|template-fill)
      printf 'template-fill\tdeterministic' ;;
    decision-log|append-section|capped-append)
      printf 'append-section\thybrid' ;;
    free-form|agentic|prompt-guided|prompt-guided-amend)
      printf 'prompt-guided-amend\tllm-mediated' ;;
    *)
      printf '\t' ;;  # unknown intent — caller block-and-logs
  esac
}

mode_propose() {
  local prompt_id destination_glob merge_intent upstream_csv body_goal
  prompt_id=""
  destination_glob=""
  merge_intent=""
  upstream_csv=""
  body_goal=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-id)         prompt_id="$2";         shift 2 ;;
      --destination-glob)  destination_glob="$2";  shift 2 ;;
      --merge-intent)      merge_intent="$2";      shift 2 ;;
      --upstream-writers)  upstream_csv="$2";      shift 2 ;;
      --goal)              body_goal="$2";         shift 2 ;;
      --proposed-by)       PROPOSED_BY="$2";       shift 2 ;;
      *) shift ;;
    esac
  done

  # Step (i): target destination (glob) + upstream writers required.
  if [ -z "$prompt_id" ]; then
    printf 'doc-amender-prompt.mode_propose: --prompt-id <id> required\n' >&2
    return 2
  fi
  case "$prompt_id" in
    */*|.*)
      printf 'doc-amender-prompt.mode_propose: --prompt-id must be filename-safe (got: %s)\n' "$prompt_id" >&2
      return 2
      ;;
  esac
  if [ -z "$destination_glob" ]; then
    printf 'doc-amender-prompt.mode_propose: --destination-glob <glob> required (the target destination set)\n' >&2
    return 2
  fi

  # Step (ii): interview the operator on per-destination merge intent → strategy.
  if [ -z "$merge_intent" ]; then
    printf 'doc-amender-prompt.mode_propose: --merge-intent required (one of: table-upsert|decision-log|free-form — maps to amendment_strategy)\n' >&2
    return 2
  fi
  local strategy_pm strategy persistence_mode
  strategy_pm=$(_dap_intent_to_strategy "$merge_intent")
  strategy=$(printf '%s' "$strategy_pm" | cut -f1)
  persistence_mode=$(printf '%s' "$strategy_pm" | cut -f2)
  if [ -z "$strategy" ] || [ -z "$persistence_mode" ]; then
    printf 'doc-amender-prompt.mode_propose: unknown --merge-intent: %s (valid: table-upsert, decision-log, free-form)\n' "$merge_intent" >&2
    return 2
  fi

  local today
  today=$(date -u +%Y-%m-%d)

  # Step (iii): render a contract-compliant prompt asset (frontmatter + body).
  # frontmatter_required per doc-amender-prompt.md.json: type, prompt_id,
  # amendment_strategy, destination_glob, survivorship_policy, created, updated.
  local frontmatter_json
  frontmatter_json=$(jq -nc \
    --arg type "doc-amender-prompt" \
    --arg prompt_id "$prompt_id" \
    --arg amendment_strategy "$strategy" \
    --arg persistence_mode "$persistence_mode" \
    --arg destination_glob "$destination_glob" \
    --arg survivorship_policy "operator-edit-wins" \
    --arg created "$today" \
    --arg updated "$today" \
    '{
      type: $type,
      prompt_id: $prompt_id,
      amendment_strategy: $amendment_strategy,
      persistence_mode: $persistence_mode,
      destination_glob: $destination_glob,
      survivorship_policy: $survivorship_policy,
      created: $created,
      updated: $updated
    }')

  # Body: a contract body_section_allowlist-aligned skeleton. The operator (or
  # the invoking model) refines the Prompt section; LLM-use to draft the prompt
  # body is in-bounds (a prompt asset is config/content, not a SKILL body —
  # the no-skill-code-generation rule does not bar it).
  local body
  if [ -z "$body_goal" ]; then
    body_goal="Reconcile the upstream writer packet into the destination per the merge intent."
  fi
  body=$(printf '# Goal\n\n%s\n\n# Variables\n\nThe 6-variable namespace is available: packet_body, destination_current_content, destination_path, upstream_writers, writer_metadata, amendment_history.\n\n# Prompt\n\n(Operator: author the reconciliation instruction here — how a new packet merges INTO the existing destination_current_content for merge-intent=%s.)\n\n# Output Format\n\nReturn the FULL amended destination body (the doc-amender round-trips it as an amender-replacement packet; the reconciler writes it).\n' "$body_goal" "$merge_intent")

  local upstream_json
  if [ -n "$upstream_csv" ]; then
    upstream_json=$(printf '%s' "$upstream_csv" | jq -Rc 'split(",") | map(select(length > 0))')
  else
    upstream_json='[]'
  fi

  # Emit the proposal JSON.
  jq -nc \
    --arg prompt_id "$prompt_id" \
    --arg proposed_by "${PROPOSED_BY:-user-direct}" \
    --arg destination_glob "$destination_glob" \
    --arg merge_intent "$merge_intent" \
    --arg body "$body" \
    --argjson frontmatter "$frontmatter_json" \
    --argjson upstream "$upstream_json" \
    '
      {
        kind: "doc-amender-prompt",
        target: $prompt_id,
        proposed_by: $proposed_by,
        prompt_asset: {
          prompt_id: $prompt_id,
          frontmatter: $frontmatter,
          body: $body
        },
        fan_in: {
          consumer: $destination_glob,
          upstream_writers: $upstream,
          amendment_strategy: $frontmatter.amendment_strategy
        },
        notes: [
          "Layer-3 doc-amender prompt authoring (5th registration class). The prompt asset is the create-time companion to the consume-time runtime (skills/doc-amender/process.sh).",
          "merge-intent " + $merge_intent + " maps to amendment_strategy=" + $frontmatter.amendment_strategy + " / persistence_mode=" + $frontmatter.persistence_mode + " (per the doc-amender-prompt.md.json contract).",
          "commit validates the frontmatter against doc-amender-prompt.md.json BEFORE the create-only write to $VAULT_WRITER_STATE_ROOT/prompts/<prompt_id>.md.",
          "Pass --with-fan-in at commit to also append the writer-fan-in entry to governance/doc-dependencies.json."
        ]
      }
    '
}

mode_commit() {
  local proposal="$1"
  shift || true

  local with_fan_in=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-fan-in) with_fan_in=1; shift ;;
      *) shift ;;
    esac
  done

  if [ ! -r "$proposal" ]; then
    printf 'doc-amender-prompt.mode_commit: proposal file not readable: %s\n' "$proposal" >&2
    return 2
  fi

  local prompt_id frontmatter body strategy persistence_mode
  prompt_id=$(jq -r '.prompt_asset.prompt_id // empty' "$proposal")
  frontmatter=$(jq '.prompt_asset.frontmatter' "$proposal")
  body=$(jq -r '.prompt_asset.body // ""' "$proposal")
  strategy=$(jq -r '.prompt_asset.frontmatter.amendment_strategy // empty' "$proposal")
  persistence_mode=$(jq -r '.prompt_asset.frontmatter.persistence_mode // empty' "$proposal")

  if [ -z "$prompt_id" ] || [ "$frontmatter" = "null" ]; then
    printf 'doc-amender-prompt.mode_commit: proposal missing .prompt_asset.{prompt_id,frontmatter}\n' >&2
    return 2
  fi

  # ---- Step (iv): validate against doc-amender-prompt.md.json BEFORE write ----
  local contract
  contract=$(_dap_contract_path)
  if [ ! -r "$contract" ]; then
    printf 'doc-amender-prompt.mode_commit: contract not readable: %s\n' "$contract" >&2
    return 3
  fi

  # frontmatter_required present?
  local missing
  missing=$(jq -r --argjson fm "$frontmatter" '
    [ .frontmatter_required[] | select( ($fm[.] // null) == null ) ] | join(",")
  ' "$contract" 2>/dev/null)
  if [ -n "$missing" ]; then
    printf 'doc-amender-prompt.mode_commit: BLOCK — frontmatter missing required field(s): %s\n' "$missing" >&2
    return 3
  fi

  # frontmatter_enums honored (type / amendment_strategy / persistence_mode /
  # survivorship_policy)?
  local enum_bad
  enum_bad=$(jq -r --argjson fm "$frontmatter" '
    [ .frontmatter_enums | to_entries[]
      | . as $e
      | select( ($fm[$e.key] // null) != null )
      | select( ($e.value | index($fm[$e.key])) == null )
      | $e.key
    ] | join(",")
  ' "$contract" 2>/dev/null)
  if [ -n "$enum_bad" ]; then
    printf 'doc-amender-prompt.mode_commit: BLOCK — frontmatter enum violation on field(s): %s\n' "$enum_bad" >&2
    return 3
  fi

  # amendment_strategy ↔ persistence_mode consistency (the contract mapping).
  if [ -n "$strategy" ] && [ -n "$persistence_mode" ]; then
    local expected_pm
    expected_pm=$(jq -r --arg s "$strategy" '.persistence_mode_detail.persistence_mode_default[$s] // empty' "$contract" 2>/dev/null)
    if [ -n "$expected_pm" ] && [ "$expected_pm" != "$persistence_mode" ]; then
      printf 'doc-amender-prompt.mode_commit: BLOCK — persistence_mode=%s inconsistent with amendment_strategy=%s (contract default: %s)\n' \
        "$persistence_mode" "$strategy" "$expected_pm" >&2
      return 3
    fi
  fi

  # ---- Step (v): create-only write to $VAULT_WRITER_STATE_ROOT/prompts/<id>.md ----
  local prompts_root prompt_path
  prompts_root=$(_dap_prompts_root)
  prompt_path="$prompts_root/$prompt_id.md"

  if [ -e "$prompt_path" ]; then
    printf 'doc-amender-prompt.mode_commit: BLOCK — prompt already exists (create-only): %s\n' "$prompt_path" >&2
    return 4
  fi

  if ! mkdir -p "$prompts_root" 2>/dev/null; then
    printf 'doc-amender-prompt.mode_commit: cannot create prompts root: %s\n' "$prompts_root" >&2
    return 3
  fi

  local tmpdir
  tmpdir=$(mktemp -d -t govern-register-doc-amender-prompt.XXXXXX) || {
    printf 'doc-amender-prompt.mode_commit: tempdir creation failed\n' >&2
    return 3
  }
  trap 'rm -rf "$tmpdir"' RETURN

  local prompt_yaml="$tmpdir/frontmatter.yaml"
  if ! printf '%s' "$frontmatter" | python3 -c '
import sys, json, yaml
data = json.loads(sys.stdin.read())
sys.stdout.write(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
' > "$prompt_yaml" 2>/dev/null; then
    printf 'doc-amender-prompt.mode_commit: frontmatter YAML render failed (python3 + pyyaml required)\n' >&2
    return 3
  fi

  local prompt_tmp="$tmpdir/prompt.md"
  {
    printf -- '---\n'
    cat "$prompt_yaml"
    printf -- '---\n\n'
    printf '%s\n' "$body"
  } > "$prompt_tmp" || {
    printf 'doc-amender-prompt.mode_commit: prompt asset composition failed\n' >&2
    return 3
  }

  # Create-only atomic write (re-check non-existence right before rename).
  if [ -e "$prompt_path" ]; then
    printf 'doc-amender-prompt.mode_commit: BLOCK — prompt appeared (race): %s\n' "$prompt_path" >&2
    return 4
  fi
  if ! mv -f "$prompt_tmp" "$prompt_path" 2>/dev/null; then
    printf 'doc-amender-prompt.mode_commit: prompt asset write failed: %s\n' "$prompt_path" >&2
    return 3
  fi
  printf 'doc-amender-prompt.mode_commit: wrote prompt asset %s\n' "$prompt_path" >&2

  # ---- Step (vi): optionally create/extend the writer-fan-in doc-deps entry ----
  if [ "$with_fan_in" = "1" ]; then
    local doc_deps consumer upstream amendment_strategy entry_id
    doc_deps="${CLAUDE_HOME:-$HOME/.claude}/governance/doc-dependencies.json"
    if [ ! -w "$doc_deps" ]; then
      printf 'doc-amender-prompt.mode_commit: WARN — doc-dependencies.json not writable (%s); prompt asset written, fan-in entry SKIPPED\n' "$doc_deps" >&2
      return 0
    fi
    consumer=$(jq -r '.fan_in.consumer // empty' "$proposal")
    upstream=$(jq -c '.fan_in.upstream_writers // []' "$proposal")
    amendment_strategy=$(jq -r '.fan_in.amendment_strategy // "prompt-guided-amend"' "$proposal")
    entry_id="${prompt_id}-fan-in"
    # Create-only on the entry id (block-and-log on collision).
    if jq -e --arg id "$entry_id" '.entries[]? | select(.id==$id)' "$doc_deps" >/dev/null 2>&1; then
      printf 'doc-amender-prompt.mode_commit: WARN — doc-deps fan-in entry %s already exists; prompt asset written, entry NOT modified\n' "$entry_id" >&2
      return 0
    fi
    local dd_tmp="$tmpdir/doc-deps.json"
    if jq --arg id "$entry_id" --arg consumer "$consumer" --argjson upstream "$upstream" --arg strategy "$amendment_strategy" \
        '.entries += [{id:$id, kind:"writer-fan-in", consumer:$consumer, upstream_writers:$upstream, amendment_strategy:$strategy, rename_history:[]}]' \
        "$doc_deps" > "$dd_tmp" 2>/dev/null && jq empty "$dd_tmp" >/dev/null 2>&1; then
      mv -f "$dd_tmp" "$doc_deps" && \
        printf 'doc-amender-prompt.mode_commit: appended writer-fan-in entry %s to %s\n' "$entry_id" "$doc_deps" >&2
    else
      printf 'doc-amender-prompt.mode_commit: WARN — doc-deps fan-in append failed; prompt asset written, entry SKIPPED\n' >&2
    fi
  fi

  return 0
}
