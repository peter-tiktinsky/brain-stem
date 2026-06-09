# hooks/lib/context-pressure.sh — context-pressure.json producer.
# Source this file — do not execute it.
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/context-pressure.sh"
#   write_context_pressure "$TRANSCRIPT_PATH" "$PRESSURE_FILE"
# THE MISSING WRITER (sweep item 1 /). The R-26 bands (prompt-context.sh
# warn/mandate; stop-checkpoint-check.sh freshness/existence gates) read
# `$CLAUDE_STATE_ROOT/sessions/<sid>/context-pressure.json :: .pct`, named by the
# binding spec as "the .pct source for the bands" — but the clean-room
# rebuild never ported a producer, so .pct defaulted to 0 and every band was inert
# in fresh installs. This helper computes pct from Claude Code's session transcript
# (the `transcript_path` every hook receives on stdin) and writes the file the bands
# read. It is the single SoT for the computation so prompt-context.sh and
# stop-checkpoint-check.sh never diverge.
# DESIGN NOTE: net-new (the spec names the consumer, not a producer). pct = the most
# recent assistant turn's input-side context (input + cache_read + cache_creation
# tokens) over the model's context window. Window: $CLAUDE_CONTEXT_WINDOW env wins;
# else inferred 1,000,000 for a 1m-context model id, else 200,000 (the conservative
# default — a 1m adopter who leaves it unset just gets earlier, safe checkpoints).
# FAILURE MODE: graceful no-op. Returns non-zero and writes NOTHING when the
# transcript is absent/unreadable, jq is missing, or no usage block exists — so the
# bands degrade to exactly the pre-behavior (pct=0), never an error and never a
# stale clobber. Atomic temp+rename. Bash 3.2 clean (R-23).

write_context_pressure() {
  local transcript="$1" out="$2" window="${3:-}"
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 1
  [ -n "$out" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # Input-side context tokens of the LAST usage block in the transcript (the most
  # recent assistant turn). objects-guard every index so a non-object/partial line
  # can never error under the caller's `set -euo pipefail`.
  local used
  used=$(jq -rs '
    [ .[]? | objects
      | ((.message? | objects | .usage?) // .usage?)
      | objects ] as $u
    | if ($u | length) == 0 then empty
      else ($u[-1]) as $l
        | (($l.input_tokens? // 0)
           + ($l.cache_read_input_tokens? // 0)
           + ($l.cache_creation_input_tokens? // 0))
      end' "$transcript" 2>/dev/null)
  case "$used" in ''|*[!0-9]*) return 1 ;; esac
  [ "$used" -gt 0 ] || return 1

  if [ -z "$window" ]; then
    if [ -n "${CLAUDE_CONTEXT_WINDOW:-}" ]; then
      window="$CLAUDE_CONTEXT_WINDOW"
    else
      local model
      model=$(jq -rs '[ .[]? | objects | (.message? | objects | .model?) // empty ] | last // ""' "$transcript" 2>/dev/null)
      case "$model" in
        *1m*|*1M*) window=1000000 ;;
        *) window=200000 ;;
      esac
    fi
  fi
  case "$window" in ''|*[!0-9]*) window=200000 ;; esac
  [ "$window" -gt 0 ] || window=200000

  local pct
  pct=$(( used * 100 / window ))
  [ "$pct" -gt 100 ] && pct=100

  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  printf '{"pct":%s,"input_tokens":%s,"window":%s}\n' "$pct" "$used" "$window" > "$out.tmp" 2>/dev/null \
    && mv "$out.tmp" "$out" 2>/dev/null || { rm -f "$out.tmp" 2>/dev/null; return 1; }
  return 0
}
