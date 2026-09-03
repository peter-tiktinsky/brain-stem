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
argument-hint: "<descriptive-slug> [--master --sub <sub-slug>] [--add-subplan <master-NN-slug> --sub <sub-slug>] [--title <title>] [--section <backlog-section>] [--force-slug]"
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
| **`--add-subplan`** | `/new-plan --add-subplan <master-NN-slug> --sub <sub-slug>` | new sub-plan quartet into an existing master; registers it in the master's `sub_plans[]` |

**Flat depth-2 is the DEFAULT emission.** A master structure is NEVER auto-emitted — it
requires the explicit `--master` flag. The default path produces a single `type: plan`
manifest with no `sub_plans[]`.

**`--add-subplan` is the only sub-plan emit path.** The scaffolder writes the new sub-plan
quartet and adds a skeleton entry to the master's `sub_plans[]` aggregate (`status` seed =
`planned`); the librarian reconciler does the pull-based status fill — the scaffolder never
hand-fills the aggregate beyond the skeleton seed.

## Designed-but-deferred / not built

- **flat→master graduation — DESIGNED-BUT-DEFERRED.** A flat plan that outgrows depth-2 is
  conceptually graduated to a master by: (1) `--master` scaffolding a new master shell,
  (2) relocating the flat plan's body into a first sub-plan, (3) re-pointing
  `parent_plan`/`type`. This graduation PATH is **not built** — there is no `graduate`
  command. The intended manual route remains: scaffold a master with `--master` and migrate
  by hand. (Captured here as design intent; the path is deliberately out of MVP scope.)
- **`--promote-master` — NOT built.** No such flag exists. `--add-subplan` is the only way to
  add a sub-plan to a master; there is no flag that promotes/auto-grafts a flat plan into a
  master.

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
| Files written | **flat:** 5 files (`spec.md`, `tasks.md`, `handoff.md`, `manifest.json`, `00-ideation-brief.md`) under `<plans-root>/NN-<slug>/`. **--master:** master quartet (4) + first sub-plan quartet (4) under `NN-<slug>/` and `NN-<slug>/01-<sub-slug>/`. **--add-subplan:** sub-plan quartet (4) under `NN-<slug>/NN-<sub-slug>/` + a `sub_plans[]` skeleton append to the master manifest. |
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
| Write failure mid-scaffold | roll back created files, abort, report |

## Related

- `new-plan.sh` — the mechanical scaffolder entrypoint (flat / `--master` / `--add-subplan`).
- `lib/promote-from-inbox.sh` — the internal R-34 mechanical helper: graduates an `_inbox`
  idea note into a plan dir (version-on-collision at capture; reject-on-collision at
  graduation).
- `templates/` — the 8 master/sub quartet templates + the placeholder ideation-brief template.
- `backlog-research` (peer skill) — the research-backed mode of the same scaffolder.
- `schemas/plan-manifest-schema.json` — the manifest schema the rendered manifests satisfy.
- `governance/plans-rules.json` — the quartet + slug + inbox conventions enforced.
