# Release notes — v1.8.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.8.0 is a feature release with two stories.** The first governs the **work projects** you keep under `~/work/` (the folder brain-stem surfaces into your vault as the `Work/` view): a folder you create there can now be turned into a fully-governed project workspace with one command, and a project authored from outside the vault is governed just like one opened inside it. The second makes session-close **commit-free** — `/librarian session-close` no longer commits or pushes your vault as a side-effect, and a session that ends without a formal close now gets an automatic integrity pass that keeps your vault honest on its own.

---

## Story 1 — Governed work projects

### Why this matters

brain-stem already gives `Work/` a place in your vault and ships a `deliverable` file type, but until now a folder you created inside `Work/` was governed by **nobody**. The check that runs every time the assistant saves a file only inspected paths inside the vault folder you named at setup — so a brief written from a project you launched directly on disk (`cd ~/work/acme`) landed on a `~/work/...` path the check never looked at. The most client-facing, highest-stakes content you produce was the one surface running with no governance at all, which is exactly where drift is most expensive.

**v1.8.0 closes that hole.** A folder under `~/work/` becomes a formal, governed project the moment you register it, and from then on every write into it is checked the same way the rest of your vault is — no matter whether you opened the project inside Obsidian or launched it from a terminal in `~/work/`.

### What you can now do

- **Mint a project with one command.** From inside a folder under `~/work/`, run `/govern register --kind project`. By default you get a **flat** six-file workspace — a `CLAUDE.md` (the per-project config the assistant reads when you launch there), a `hub.md` cover page, a `README`, an `updates.md` running log, and `deliverables/` and `reference/` folders. That is the whole MVP; everything beyond it is your choice.
- **Or mint a master project.** Pass `--layout master --first-sub <name>` to get a **master** project: a thin top level (`CLAUDE.md`, `hub.md`, `README`, `updates.md` — and deliberately *no* top-level `deliverables/`/`reference/`) that organizes its work into **sub-projects**, each of which owns its own `README`, `deliverables/`, and `reference/`. A sub-project is an organizational unit, not a second kind of project: it has no `CLAUDE.md` of its own and is not a separate launch context — you launch from the master.
- **Be governed from outside the vault.** Once a project is registered, a write into it from a terminal launched in `~/work/<project>` is mapped to its `Work/<project>/…` vault view *before* it is checked, so the same file-type, placement, and tag rules apply. This only happens for projects you have registered; an unregistered `~/work/` scratch folder is left completely alone.
- **Tag work by project.** A new `project` tag dimension makes tags like `#project/acme` first-class, user-facing vocabulary. It is deliberately **uncapped** — a project name is an identifier, not a category — so tagging and filtering by project never trips a tagging advisory.
- **Tie a vault writer to a project.** A *vault writer* is a system that writes notes into your vault on your behalf. You can now associate one with a project by registering it with `--project`. The writers catalog gains a `Project` column, and two new health checks flag a writer pointed at a project that does not exist, or one whose destination has drifted off its own project.
- **Grow and promote.** Add a sub-project to a master with `--add-sub <name>`. If a sub-project outgrows its master and needs its own launch context, `--adopt` promotes it to a top-level project — it is moved and given its own `CLAUDE.md` and cover page, and nothing already inside it is disturbed.

### How governance reaches `~/work/`

There is no new governance engine here. The existing write-time check is already a complete type/placement/tag enforcer; the only genuinely new mechanism is a small, project-scoped step that rewrites a physical `~/work/<project>/…` path to its `Work/<project>/…` vault view before the existing engine runs. Everything downstream — type checks, placement checks, tag checks — then fires unchanged. Registering a project records it, scaffolds the workspace, and adds a per-project routing rule the check reads; that is all it takes.

---

## Story 2 — A commit-free session-close

### Why this matters

`/librarian session-close` is the end-of-session tidy-up: it re-checks conventions, refreshes the auto-generated indexes, re-syncs your plans, and proposes (never silently applies) any file renames. Its final step used to be a **backup** — `git add`, `commit`, and `push` to your remote. That was a problem on two fronts. It contradicted the security contract, which already promised that backup "runs by hand, never automatically." And it meant the integrity subset of the close could not safely run on its own, because running it unattended would have pushed your vault without asking.

**v1.8.0 removes the backup step from the close entirely.** The close is now *structurally* commit-free — there is no commit/push path left in it to fire — which both makes the security promise literally true and clears the way for the close's integrity work to run automatically.

### What changed

- **`/librarian session-close` no longer commits or pushes.** It still re-checks conventions, refreshes indexes, re-syncs plans, and dry-run-cascades renames — it simply never runs `git commit` or `git push` anymore. Backing up is once again a deliberate, by-hand step: **`/librarian backup`**.
- **A manual close now *offers* a backup.** So you are not silently dropped, a manual `/librarian session-close` ends by asking — "N files changed; run `/librarian backup`?" — and runs it only if you say yes. The automatic path (below) never offers and never commits.
- **Sessions that end without a close get an automatic integrity pass.** If a session ends without a `/librarian session-close`, the integrity subset of the close now runs **by itself**, detached and in the background: indexes are refreshed, conventions re-checked, and plan-drift detected. It fires on a graceful exit and is backstopped at the next session start to catch crashes, kills, and terminal-closes that the graceful path misses. Because the close is now commit-free, running it unattended is safe by construction: it never commits, never pushes, never applies a rename, and never writes into your vault — its receipt lands in brain-stem's machine-local state directory, outside your notes.

The session architecture documentation describes this as a new **middle tier** between always-on registry cleanup and the on-demand full close.

---

## Who this affects

- **People who keep work under `~/work/`** get governed project workspaces, governance that follows the work even when it is launched from a terminal, project tags, and project-aware vault writers. Everything is opt-in per project.
- **People who do not use `~/work/`** are unaffected by Story 1 — nothing activates until you register a project, and an unregistered `~/work/` folder is never touched.
- **Anyone who closed sessions manually** is affected by Story 2: a manual `/librarian session-close` will no longer back up your vault. If your habit was "close, and it's pushed," replace it with "close, then run `/librarian backup`."
- **People who rarely run `/librarian session-close`** gain the automatic integrity pass — their indexes, frontmatter, and plan-drift now stay honest without any action.

> **<https://peter-tiktinsky.github.io/brain-stem-docs/>**

---

## Upgrading

Upgrade the way you always do (`bash install.sh --apply` from your local clone, or your usual upgrade flow).

**Work-project governance is additive.** The upgrade adds the `/govern register --kind project` on-ramp, the project-scaffolding files, the path mapping that governs `~/work/` projects, the `project` tag dimension, and the project-aware writer support. **None of it activates until you register a project.** If you do not keep work under `~/work/`, you can upgrade and ignore all of it; an unregistered `~/work/` folder is never read or written.

**The session-close contract change affects everyone who closed manually.** After upgrading, a manual `/librarian session-close` no longer pushes your vault — it offers `/librarian backup` instead, and the new automatic integrity pass never commits at all. Nothing is lost: your notes and the close's own work are on disk as before. But if you relied on a manual close to back up your vault, **run `/librarian backup` yourself afterward.** No setting needs changing; the new triggers are on by default and are detached, advisory, and commit-free.

The upgrade does not touch your existing notes, plans, projects, or wiki.

---

## In one sentence

brain-stem now turns a folder under `~/work/` into a fully-governed project with one command — governed even when launched from outside the vault — and makes `/librarian session-close` structurally commit-free, with an automatic integrity pass that keeps your vault honest when you forget to close and a by-hand `/librarian backup` for the times you want to push.
