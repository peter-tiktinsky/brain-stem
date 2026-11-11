---
name: new-plan
description: >
  Scaffold a governance-compliant plan directory in one invocation (spec.md, tasks.md,
  handoff.md, manifest.json, placeholder ideation brief) with the next NN- prefix assigned;
  --master emits a master+sub structure, --add-subplan adds a sub-plan to an existing master.
  Use when creating a plan directly from an idea with no research pass; for research-first
  creation route to /backlog-research. Trigger on: "/new-plan", "new plan", "scaffold a plan",
  "create a plan for ...".
disable-model-invocation: false
argument-hint: "<descriptive-slug> [--master --sub <sub-slug>] [--add-subplan <master-NN-slug> --sub <sub-slug>] [--graduate <flat-NN-slug> --sub <sub-slug> [--dry-run]] [--rollup <master-NN-slug>] [--title <title>] [--section <backlog-section>] [--force-slug]"
---

# /new-plan — Scaffolded Plan Creation (research-skip mode)

`/new-plan` is the **research-skip mode** of the ONE canonical plan scaffolder. There is one
scaffolder with multiple modes; `/new-plan` and `/backlog-research` are two front doors to it:

- **`/new-plan`** — research-skip: scaffold straight from a slug, no research pass. The
  ideation brief is a placeholder stub.
- **`/backlog-research`** — research-backed: performs the ideation analysis, then scaffolds
  the same quartet with a filled brief. Route here when the user wants deep research before
  planning.

The mechanical engine is `new-plan.sh`; the `_inbox` graduation helper is
`lib/promote-from-inbox.sh`; the quartet templates are under `templates/`.

## Modes

| Mode | Invocation | Emits |
|------|-----------|-------|
| **research-skip (default)** | `/new-plan <slug>` | flat depth-2 quartet + placeholder brief; `type: plan` |
| **research-backed** | `/backlog-research <item>` (peer skill) | same quartet, filled brief |
| **`--master` (OPT-IN)** | `/new-plan --master <slug> --sub <sub-slug>` | master quartet + first sub-plan quartet |
| **`--add-subplan`** | `/new-plan --add-subplan <master-NN-slug> --sub <sub-slug>` | new sub-plan quartet into an existing master; registers it in the master's `sub_plans[]`, then runs the master rollup so the master `tasks.md` rows are current |
| **`--graduate`** | `/new-plan --graduate <flat-NN-slug> --sub <sub-slug> [--dry-run]` | turns a flat plan into a master whose first sub-plan is the plan's own content; the plan keeps its number |
| **`--rollup`** | `/new-plan --rollup <master-NN-slug>` | rewrites the master `tasks.md` rollup rows from the master's `sub_plans[]` aggregate |

**Flat depth-2 is the DEFAULT emission.** A master structure is NEVER auto-emitted — it
requires the explicit `--master` flag. The default path produces a single `type: plan`
manifest with no `sub_plans[]`.

**`--add-subplan` is the only sub-plan emit path.** The scaffolder writes the new sub-plan
quartet and adds a skeleton entry to the master's `sub_plans[]` aggregate (`status` seed =
`planned`); the librarian reconciler does the pull-based status fill — the scaffolder never
hand-fills the aggregate beyond the skeleton seed.

## Graduating a flat plan and rolling up a master

Two commands restructure a plan that already exists. Both are mechanical, hold a lock while
they write, and refuse before they write anything.

`new-plan.sh --graduate <flat-NN-slug> --sub <sub-slug> [--dry-run]` turns a flat plan into a
master whose first sub-plan is the flat plan's own content. The plan directory keeps its name
and its number. Its whole content moves into `01-<sub-slug>/`; the directory then holds the
master quartet, rendered from the master templates, beside that sub-plan. The sub-plan manifest
and the frontmatter lines of the moved files are rewritten, and the master manifest lists the
sub-plan. `--dry-run` runs every check, takes no lock and writes nothing. After the restructure
the command re-derives the binder surfaces once for the master manifest and once for the
sub-plan manifest, then names `/librarian backlog-index` as the next step. It never writes
`_backlog.md`.

`new-plan.sh --rollup <master-NN-slug>` pulls the master's `sub_plans[]` aggregate from the
sub-plan manifests and rewrites the master `tasks.md` rollup rows from it, one row per
sub-plan. It changes those rows and nothing else in the file.

Exit codes: 0 done or a dry run, 1 aborted, 2 usage.

A graduation refuses, with `new-plan: aborted — <reason>` and the plans tree untouched, when:

- **not a flat plan** — the target is a master or a sub-plan, already lists `sub_plans[]`, or
  is not a plan directory with a readable manifest.
- **terminal plan** — its status is `completed` or `superseded`; a terminal plan is a closed
  record and does not graduate.
- **armed plan** — it is the plan armed for its spoke; disarm it first.
- **numbered entry** — the directory already holds an `NN-` entry, which a flat plan never has.
- **invalid sub slug** — the sub slug breaks the scaffolder's slug rules (shape, length, shame
  slug).
- **schema-invalid rewrite** — either rewritten manifest fails `plan-manifest-schema.json`; the
  master is checked first.

A failure while writing is rolled back, so the plan directory is as it was.
Graduation changes structure, never lifecycle state.

## Designed-but-deferred / not built

- **`--promote-master` — NOT built.** No such flag exists. `--add-subplan` adds a sub-plan to
  a master and `--graduate` turns a flat plan into one.

## Placeholder ideation brief

The research-skip mode **scaffolds a placeholder `00-ideation-brief.md`** from
`templates/00-ideation-brief.md.tmpl`. It is clearly marked as a research-skip stub: either
fill it via `/backlog-research`, or leave it as a placeholder when the plan needs no ideation
record. (The brief's body freezes post-Session-1; later shifts land as a prepended
amendment-pointer-block, per the ideation-brief body-structure contract.)

## Plan Creation Conventions enforced (by construction)

`new-plan.sh` enforces the operator Plan Creation Conventions at the creation gate:

1. **Descriptive slug.** Slug must match `^[a-z0-9][a-z0-9-]*[a-z0-9]$` (3–60 chars). The
   shame-slug regex `^[a-z]+-[a-z]+ing-[a-z]+$` (adjective-gerund-noun auto-generator pattern)
   is rejected unless `--force-slug` is passed.
2. **Next-prefix in creation order.** The plan-root `NN-` prefix is the next integer after the
   highest existing prefix, zero-padded — assigned at creation.
3. **Sub-plan numbering in execution order.** `--add-subplan` assigns the next `NN-` ordinal in
   execution order (not creation order); `--master` seeds the first sub-plan at `01-`.
4. **Status header.** Every rendered file carries a canonical status (manifest `status` field;
   markdown `**Status:**` / frontmatter `status:`). The 6-state canonical vocabulary is used
   (`researching | planned | in-progress | paused | completed | superseded`; `completed` +
   `superseded` terminal) — never a non-canonical token.
5. **`parent_plan` on depth-≥3 sub-files.** Sub-plan `spec.md` / `tasks.md` / `manifest.json`
   carry `parent_plan` by construction; `handoff.md` is exempt at any depth.

## Output Contract

| Aspect | Value |
|---|---|
| Files written | **flat:** 5 files (`spec.md`, `tasks.md`, `handoff.md`, `manifest.json`, `00-ideation-brief.md`) under `<plans-root>/NN-<slug>/`. **--master:** master quartet (4) + first sub-plan quartet (4) under `NN-<slug>/` and `NN-<slug>/01-<sub-slug>/`. **--add-subplan:** sub-plan quartet (4) under `NN-<slug>/NN-<sub-slug>/` + a `sub_plans[]` skeleton append to the master manifest, then the rollup rows of the master `tasks.md` (a rollup that cannot run prints one NOTE naming `new-plan.sh --rollup` and the exit code stays 0). **--graduate:** the plan's whole content moves under `NN-<slug>/01-<sub-slug>/`, the master quartet (4) is rendered at `NN-<slug>/`, and the sub-plan manifest, the frontmatter lines of the moved `spec.md` / `tasks.md` / `handoff.md` / `00-ideation-brief.md` and the master manifest are rewritten. **--rollup:** the rollup rows of the master `tasks.md`, plus the master manifest's `sub_plans[]` when the pull changed it. |
| Schema type | plan manifests validated against `schemas/plan-manifest-schema.json` (`type: plan` / `master` / `sub-plan`; ADR if/then type-binding). Markdown bodies conform to the `governance/file-type-contracts/{spec,tasks,handoff,manifest,ideation-brief}.md.json` contracts. |
| Pre-write validation | (a) slug shape + shame-slug regex; (b) length 3–60; (c) next-prefix computation; (d) base-slug collision check; (e) template presence; (f) for `--add-subplan`: master exists + `type == master` + sub-slug collision check. All run BEFORE any write. |
| Failure mode | **block-and-log** — validate fully before any write; on any mid-scaffold write failure, roll back the created directory and report. Never leave partial state; never write-and-hope. |

## Failure mode reference

| Failure | Action |
|---|---|
| Invalid slug shape / length | abort before any write |
| Shame slug without `--force-slug` | abort before any write |
| Base-slug collision with an existing plan | abort before any write |
| Target dir already exists | abort before any write |
| Template missing | abort before any write |
| `--add-subplan` target not a master | abort before any write |
| `--graduate` target not a flat plan | abort before any write |
| `--graduate` target armed or terminal | abort before any write |
| `--rollup` target not a master | abort before any write |
| Write failure mid-scaffold | roll back created files, abort, report |

## Recipe: isolate the research reads in one subagent

The research-backed mode (`/backlog-research`) runs ten steps. Steps 2 to 4 (vault context,
infrastructure dependencies, external research) read material that is not yet in the session,
so run them as ONE subagent with a fresh context, and only its final result returns to the
main session. Do not fan out into several subagents or a workflow. Each extra subagent
re-creates the full instruction block, and these reads have no interrupt or resume value to
pay for that.

Steps 5 to 10 (feasibility, alternatives, the ideation brief, the draft artifacts, the
manifest update, the report) stay in the main session, because they judge and write what the
subagent returned. Step 9 is the one setter command, the same one `skills/backlog-research/SKILL.md`
names in its step 9:
`${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/field-set.sh plan set <manifest> status=planned disposition=<disposition>`

## Arming the active plan

The active-plan pointer (`<plans-root>/_projects/<spoke>/.active-plan`) names the plan a spoke is building;
the readers of `hooks/lib/active-plan-resolve.sh` take their armed path from it. Two commands write it:

```
bash ${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/active-plan.sh set <plan-key> [<sp>|.] [--project <spoke-key>] [--plans-root DIR]
bash ${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/active-plan.sh clear [--project <spoke-key>] [--plans-root DIR]
```

`set` writes the plan key to the spoke's pointer (the spoke is `--project`, else the plan manifest's own
`project`, checked against the anchored-spoke registry) and, when `<sp>` is given, the sub-plan to
`<plan>/.active-sp`. It stamps the plan in-progress through hooks/lib/field-set.sh plan set, when the manifest
the pointer resolves to is planned or paused; an in-progress plan is left as it is, so a second `set` changes
nothing. It refuses a completed or superseded plan, and it refuses a plan that is not ready to arm (any other
status, or none), before it writes anything. `clear` removes the pointer and leaves the plan's status alone
(without `--project` the spoke is the one the working directory resolves to). Neither command looks at
the plan's review state or where it is being built.

## Related

- `lib/active-plan.sh` — the `set` / `clear` verb for the active-plan pointer; `set` stamps the plan in-progress
  through the field setter and refuses a terminal plan.
- `new-plan.sh` — the mechanical scaffolder entrypoint (flat / `--master` / `--add-subplan` / `--graduate` / `--rollup`).
- `lib/promote-from-inbox.sh` — the internal R-34 mechanical helper: graduates an `_inbox`
  idea note into a plan dir (version-on-collision at capture; reject-on-collision at
  graduation).
- `lib/master-rollup.sh` — the `--rollup` engine: pulls the master's `sub_plans[]` and rewrites
  the rollup rows of the master `tasks.md`.
- `lib/graduate-plan.sh` — the `--graduate` engine: validates, takes the plans-root lock,
  restructures the plan and rolls back on any failure.
- `lib/after-write.sh` — sourced by the two engines: runs the binder refresh and the manifest
  verify for a manifest a script wrote.
- `templates/` — the 8 master/sub quartet templates + the placeholder ideation-brief template.
- `backlog-research` (peer skill) — the research-backed mode of the same scaffolder.
- `schemas/plan-manifest-schema.json` — the manifest schema the rendered manifests satisfy.
- `governance/plans-rules.json` — the quartet + slug + inbox conventions enforced.
