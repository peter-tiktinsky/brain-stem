# orchestrator/

The autonomous-orchestration + dispatch engine. A propose-and-gate
orchestrator — HITL/HOTL-gated, NOT an autonomous daemon. No task fires
without a human reasoning/approval point.

## What's here

| Path | Role |
|---|---|
| `dispatch.sh` | Unified entry point. Routes `--plan` / `--job` / `--cron` / `--batch` plus queue ops (`--list-pending` / `--cancel` / `--hold` / `--unhold` / `--queue-status`). `--plan <slug>` execs `plan-runner.sh` on the resolved master manifest; `--job <name>` execs `job-runner.sh` with the resolved prompt file. |
| `plan-runner.sh` | The manifest-driven master/sub DAG-walker. Walks a master manifest's `sub_plans[]` in topological order (honoring each sub's `dependencies.{parallel_ok,blocks}`) and dispatches each sub-plan's `tasks[]` as worker briefs through `dispatch.sh --job → job-runner.sh`. Hosts the prompt-file convention and the HITL/HOTL gate. |
| `job-runner.sh` | The functional dispatch engine: `claude -p` execution, portable timeout, budget caps, idle-watchdog, pre/post git-snapshot verifier, exit-code classification, structured JSON results. |
| `lib/idle-watchdog.sh` | Size-based stream-json silence watchdog for backgrounded `claude -p` calls (SIGTERM → grace → SIGKILL, then classify). |
| `lib/claude-p.sh` | Post-kill `claude -p` exit classifier (cold-start-hang vs stalled-mid-run). |
| `lib/tripwire.sh` | Single choke-point for tripwire-log writes (ISO-prefixed TSV; write-side dedup). |
| `state/decision-quality-events.jsonl` | `DQ_EVENTS_PATH` default state file (decision-quality telemetry; seeded empty). |

The queue-persistence library `execution-queue.sh` lives at `hooks/lib/`
(`dispatch.sh` sources it for the `--overnight` / `--delay ≥4h` timing modes
and the queue ops).

## How a plan runs end-to-end

```
dispatch.sh --plan <slug>
  → resolve_plan → <master-manifest>
    → plan-runner.sh <master-manifest>
      → topological walk of master sub_plans[] (dependencies.blocks)
        → per sub-plan, per task in tasks[]:
            resolve worker brief by convention $JOBS_DIR/<task-id>.md
            HITL/HOTL gate the task
            dispatch.sh --job <task-id> → job-runner.sh --prompt-file <brief>
```

## tasks[].prompt_file resolution — Convention

`plan-runner.sh` resolves each task's worker brief by **convention**:

```
$JOBS_DIR/<task-id>.md
```

where `$JOBS_DIR = orchestrator/jobs`. There is **no** `tasks[].prompt_file`
schema field — the `plan-manifest-schema.json` `tasks[]` item carries
`id` / `title` / `description` / `acceptance_criteria` / `depends_on` /
`parallel_group` / `allowed_tools` / `max_budget_usd`, and adding a
`prompt_file` field is out of scope (YAGNI /
anti-speculative-generality — the convention needs no schema change). The
resolved brief path is handed to `dispatch.sh --job`, which execs
`job-runner.sh --prompt-file <brief>` (the existing contract).

## HITL/HOTL gate — the v1.0.0 safety floor

`plan-runner.sh` gates every task before dispatch:

- **HITL** (human-in-the-loop, approve-before-act): tasks whose owning
  manifest declares `live_mutation_scope.enabled == true`, or a task marked
  irreversible. The runner halts and requires an explicit human
  reasoning/approval point (`PLAN_RUNNER_APPROVE=1`); it never auto-proceeds.
- **HOTL** (human-on-the-loop): reversible tasks — the runner proposes the
  dispatch and proceeds under human supervision.

This gate is **independent** of the dispatch-governance layer (Pre-Dispatch
Scoping + brief-lint + circuit-breaker). It is the
propose-and-gate primitive and the independent v1.0.0 safety
floor — deferring the governance layer does not
leave the runner ungated.

## Sub-peer isolation (R-63)

Cross-sub ordering routes through the master `sub_plans[]` / `dependencies`.
A sub-plan must not declare a `dependencies` edge directly to a sibling sub;
such edges are advisory (R-63) and the walker computes its order from the
master-level DAG.
