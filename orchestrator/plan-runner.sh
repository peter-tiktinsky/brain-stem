#!/bin/bash
# orchestrator/plan-runner.sh — manifest-driven master/sub DAG-walker.
#
# The connector
# dispatch.sh:206 calls: `exec bash plan-runner.sh <resolved-master-manifest>`.
# Completes the --plan route on the pre-existing, fully-functional
# dispatch.sh / job-runner.sh dispatch engine — it is NOT a new execution
# engine. It walks a master manifest's sub_plans[] in topological order
# (honoring each sub's dependencies.{parallel_ok,blocks}), and dispatches each
# sub-plan's tasks[] as worker briefs through the existing
# `dispatch.sh --job → job-runner.sh` path.
#
# Shape: a propose-and-gate orchestrator, the CC-native
# shape — NOT an autonomous daemon. No task fires without a human
# reasoning/approval point (see HITL/HOTL gate below).
#
# tasks[].prompt_file resolution (Convention)
# Each task's worker brief is resolved by CONVENTION at:
#
#     $JOBS_DIR/<task-id>.md
#
# where $JOBS_DIR = $SCRIPT_DIR/jobs (the dispatch.sh jobs dir). There is NO
# tasks[].prompt_file schema field — the plan-manifest-schema.json
# tasks[] item carries id/title/description/acceptance_criteria/depends_on/
# parallel_group/allowed_tools/max_budget_usd (additionalProperties:true), and
# NO prompt_file. Adding one is explicitly out of scope. YAGNI /
# anti-speculative-generality: the convention needs no
# schema change. The resolved brief path is handed to `dispatch.sh --job`,
# which execs `job-runner.sh --prompt-file <brief>` (the existing contract).
# This convention is also documented in orchestrator/README.md.
#
# HITL/HOTL gate wiring (the v1.0.0 safety floor)
# Before dispatching ANY task the runner gates it:
#   * HITL (human-in-the-loop, approve-before-act): tasks whose owning manifest
#     declares live_mutation_scope.enabled==true, OR a task marked irreversible.
#     The runner STOPS and requires an explicit human reasoning/approval point;
#     it never auto-proceeds. (schema live_mutation_scope.)
#   * HOTL (human-on-the-loop): reversible tasks — the runner proposes the
#     dispatch and proceeds, with the human supervising the loop.
# This gate is INDEPENDENT of the dispatch-governance layer — it is the
# propose-and-gate primitive and the independent v1.0.0 safety floor.
#
# Sub-peer isolation: cross-sub ordering routes through the master
# sub_plans[]/dependencies — the walker never honors a sub→sibling-sub edge
# directly (R-63 advisory).
#
# Bash 3.2 clean (R-23): no associative arrays, no mapfile/readarray, no
# parameter-expansion case conversion, no GNU-only constructs.

set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="$SCRIPT_DIR/jobs"
DISPATCH="$SCRIPT_DIR/dispatch.sh"

MASTER_MANIFEST="${1:-}"
if [ -z "$MASTER_MANIFEST" ] || [ ! -f "$MASTER_MANIFEST" ]; then
  echo "Usage: plan-runner.sh <master-manifest>" >&2
  echo "ERROR: master manifest not found: ${MASTER_MANIFEST:-<unset>}" >&2
  exit 1
fi

PLAN_DIR="$(dirname "$MASTER_MANIFEST")"

# --- HITL/HOTL gate -------------------------------------------------
# Classifies a (sub-plan manifest, task) pair and gates before dispatch.
# Returns 0 to proceed, non-zero to halt. live_mutation_scope.enabled==true
# OR a truthy task .irreversible field => HITL (approve-before-act).
gate_task() {
  local sub_manifest="$1" task_id="$2"
  local live_enabled irreversible mode

  live_enabled=$(jq -r '.live_mutation_scope.enabled // false' "$sub_manifest" 2>/dev/null)
  irreversible=$(jq -r --arg id "$task_id" \
    '(.tasks[]? | select(.id == $id) | .irreversible) // false' "$sub_manifest" 2>/dev/null)

  if [ "$live_enabled" = "true" ] || [ "$irreversible" = "true" ]; then
    mode="HITL"
  else
    mode="HOTL"
  fi

  if [ "$mode" = "HITL" ]; then
    echo "  [HITL] task $task_id is irreversible / under a live_mutation_scope gate." >&2
    echo "  [HITL] APPROVE-BEFORE-ACT: a human reasoning/approval point is required before dispatch." >&2
    # propose-and-gate: never auto-proceed. PLAN_RUNNER_APPROVE=1 is the
    # explicit human approval signal (set by the supervising operator after
    # reviewing the proposed dispatch); absent it, the runner halts.
    if [ "${PLAN_RUNNER_APPROVE:-}" != "1" ]; then
      echo "  [HITL] HALT: no approval signal (set PLAN_RUNNER_APPROVE=1 to authorize). Not an autonomous daemon." >&2
      return 1
    fi
    echo "  [HITL] approval signal present — proceeding under explicit human authorization." >&2
  else
    echo "  [HOTL] task $task_id is reversible — proposing dispatch (human-on-the-loop)." >&2
  fi
  return 0
}

# --- Dispatch one sub-plan's tasks[] via dispatch.sh --job ----
dispatch_sub() {
  local slug="$1"
  local sub_manifest="$PLAN_DIR/$slug/manifest.json"
  if [ ! -f "$sub_manifest" ]; then
    # Sub-plan may live as a flat manifest peer.
    sub_manifest="$PLAN_DIR/${slug}-manifest.json"
  fi
  if [ ! -f "$sub_manifest" ]; then
    echo "ERROR: no manifest for sub-plan '$slug' (looked under $PLAN_DIR)" >&2
    return 1
  fi

  echo "=== sub-plan: $slug ($sub_manifest) ==="
  local task_count
  task_count=$(jq -r '.tasks | length' "$sub_manifest" 2>/dev/null || echo 0)
  if [ "${task_count:-0}" -eq 0 ]; then
    echo "  (no tasks[] — master/aggregate sub; nothing to dispatch)"
    return 0
  fi

  local i task_id brief
  i=0
  while [ "$i" -lt "$task_count" ]; do
    task_id=$(jq -r ".tasks[$i].id" "$sub_manifest" 2>/dev/null)
    i=$((i + 1))
    [ -z "$task_id" ] && continue

    # resolve the worker brief by convention $JOBS_DIR/<task-id>.md.
    # We validate the brief HERE, then hand the task-id (a NAME, not a path)
    # to `dispatch.sh --job <task-id>`. The brief is consumed downstream by
    # dispatch.sh resolve_job(), which resolves slug-first then falls back to
    # the exact name: it tries $JOBS_DIR/<to_slug(task-id)>.md, then
    # $JOBS_DIR/<task-id>.md (exact name), and passes the resolved path to
    # job-runner.sh as --prompt-file. Task ids are conventionally uppercase
    # (T-NN), so resolve_job lands on the SAME $JOBS_DIR/<task-id>.md file we
    # validate here via its exact-name fallback (to_slug lowercases, so the
    # slug branch only matches a deliberately lowercased twin — which the
    # convention does not create). `dispatch.sh --job` takes a NAME and
    # resolves the brief internally; it does NOT itself accept --prompt-file.
    brief="$JOBS_DIR/${task_id}.md"
    if [ ! -f "$brief" ]; then
      echo "  WARN: no brief at $brief for $task_id (convention $JOBS_DIR/<task-id>.md) — skipping" >&2
      continue
    fi

    # gate before dispatch.
    if ! gate_task "$sub_manifest" "$task_id"; then
      echo "  HALT at $task_id (gate not cleared)." >&2
      return 1
    fi

    # Dispatch through the existing dispatch.sh --job → job-runner.sh path.
    # dispatch.sh resolve_job() finds the validated $brief (exact-name
    # fallback) and execs `job-runner.sh --prompt-file <brief>` (the existing
    # contract). We route through dispatch.sh (not job-runner.sh directly) so
    # the --immediate/--overnight/--delay queue routing is preserved.
    echo "  dispatch: $task_id (brief: $brief)"
    bash "$DISPATCH" --job "$task_id" --immediate || {
      echo "  FAILED: $task_id" >&2
      return 1
    }
  done
  return 0
}

# --- Topological order of sub_plans[] honoring dependencies.blocks ----------
# Reads the master sub_plans[] slugs, then orders by each sub's
# dependencies.blocks (a sub blocks its dependents until it reaches its gate).
# Sub-peer isolation: only master-level edges are honored; a sub→sibling-sub
# edge is advisory (R-63) and ignored for the walk order computed here.
topo_order() {
  # Emit each sub slug + the slugs it blocks (TAB-separated) so an awk-free
  # bash Kahn ordering can run. Slugs come from the master sub_plans[].
  local slugs slug sub_manifest blocks
  slugs=$(jq -r '.sub_plans[]?.slug' "$MASTER_MANIFEST" 2>/dev/null)
  [ -z "$slugs" ] && return 0

  # Kahn's algorithm over the blocks edges. indeg[slug] tracked via temp file
  # (bash 3.2 has no associative arrays).
  local work indeg_file edges_file
  indeg_file=$(mktemp "${TMPDIR:-/tmp}/plan-runner-indeg.XXXXXX")
  edges_file=$(mktemp "${TMPDIR:-/tmp}/plan-runner-edges.XXXXXX")

  for slug in $slugs; do
    printf '%s\t0\n' "$slug" >> "$indeg_file"
  done

  for slug in $slugs; do
    sub_manifest="$PLAN_DIR/$slug/manifest.json"
    [ -f "$sub_manifest" ] || sub_manifest="$PLAN_DIR/${slug}-manifest.json"
    [ -f "$sub_manifest" ] || continue
    blocks=$(jq -r '.dependencies.blocks[]?' "$sub_manifest" 2>/dev/null)
    local b
    for b in $blocks; do
      # edge slug -> b ; b's in-degree += 1 (only if b is in this master's subs)
      if grep -q "^${b}	" "$indeg_file"; then
        printf '%s\t%s\n' "$slug" "$b" >> "$edges_file"
        local cur
        cur=$(grep "^${b}	" "$indeg_file" | head -1 | cut -f2)  # errexit-crash-guard-ok: FP zero-match impossible (outer grep -q at :204 guarantees a match) + errexit suppressed: topo_order runs only inside ORDER=$(topo_order) cmd-sub
        cur=$((cur + 1))
        grep -v "^${b}	" "$indeg_file" > "${indeg_file}.t" || true
        printf '%s\t%s\n' "$b" "$cur" >> "${indeg_file}.t"
        mv "${indeg_file}.t" "$indeg_file"
      fi
    done
  done

  # Kahn: repeatedly emit a zero-in-degree node, decrementing successors.
  local emitted=0 total
  total=$(wc -l < "$indeg_file" | tr -d ' ')
  while [ "$emitted" -lt "$total" ]; do
    local ready
    ready=$(grep '	0$' "$indeg_file" | head -1 | cut -f1)  # errexit-crash-guard-ok: FP errexit suppressed: topo_order runs only inside ORDER=$(topo_order) cmd-sub (bash 3.2 cmd-subs don't inherit -e); cycle zero-match handled by [ -z "$ready" ] at :222
    if [ -z "$ready" ]; then
      # Cycle or no zero-in-degree node left — emit the remainder as-is
      # (R-63: sub-peer cycles route through the master; advisory).
      grep -v '	-1$' "$indeg_file" | cut -f1
      break
    fi
    echo "$ready"
    emitted=$((emitted + 1))
    # mark emitted (-1 sentinel) + decrement successors of $ready
    grep -v "^${ready}	" "$indeg_file" > "${indeg_file}.t" || true
    printf '%s\t-1\n' "$ready" >> "${indeg_file}.t"
    mv "${indeg_file}.t" "$indeg_file"
    local succ
    succ=$(grep "^${ready}	" "$edges_file" 2>/dev/null | cut -f2)  # errexit-crash-guard-ok: FP errexit suppressed via ORDER=$(topo_order) cmd-sub; leaf-node empty succ tolerated by 'for s in $succ'
    local s
    for s in $succ; do
      local cur
      cur=$(grep "^${s}	" "$indeg_file" | head -1 | cut -f2)  # errexit-crash-guard-ok: FP zero-match impossible (edge target $s always present in indeg_file) + errexit suppressed via cmd-sub
      [ "$cur" = "-1" ] && continue
      cur=$((cur - 1))
      grep -v "^${s}	" "$indeg_file" > "${indeg_file}.t" || true
      printf '%s\t%s\n' "$s" "$cur" >> "${indeg_file}.t"
      mv "${indeg_file}.t" "$indeg_file"
    done
  done

  rm -f "$indeg_file" "$edges_file" "${indeg_file}.t" 2>/dev/null || true
}

# Main — walk the master DAG in topo order, dispatch each sub.
echo "Plan-runner: $MASTER_MANIFEST"
ORDER=$(topo_order)
if [ -z "$ORDER" ]; then
  echo "No sub_plans[] in master manifest — nothing to walk." >&2
  exit 0
fi

for sub_slug in $ORDER; do
  dispatch_sub "$sub_slug" || {
    echo "Plan-runner HALTED at sub-plan '$sub_slug'." >&2
    exit 1
  }
done

echo "Plan-runner complete: all sub-plans dispatched in topological order."
