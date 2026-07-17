# Changelog

All notable changes to brain-stem are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project follows semantic versioning.

For longer release narratives, see `docs/release-notes-v<version>.md`.

## [v1.12.1]

Patch release — a single, important data-preservation fix. brain-stem regenerates each plan's task list from the plan's manifest, and any notes you add by hand to a task's row are meant to survive every time that list is re-rendered. In prior versions, once a task was marked done — which displays that row's identifier struck-through — the renderer stopped recognizing the row and silently dropped its hand-written note the next time the list was regenerated. It also treated the empty placeholder text in a freshly scaffolded row as if it were a real note and copied it forward on every render. This release fixes both: notes now carry forward on every row, including completed ones, and whole-cell placeholders are dropped instead of preserved. The same fix is applied to the matrix renderer that builds a plan's traceability matrix, so the two stay consistent. **Nothing you author changes and there is nothing to migrate — this stops a loss that could otherwise happen on the next render.** See the [v1.12.1 release notes](docs/release-notes-v1.12.1.md).

### Fixed

- **Hand-written notes on completed tasks are no longer lost when a task list is re-rendered.** brain-stem regenerates a plan's task list from its manifest and preserves the notes you have added to individual task rows. When a task was marked done, that row's identifier is displayed struck-through, and the renderer failed to match the struck form — so on the *next* regeneration it dropped the note on that row entirely. Notes now carry forward on every row, including done and struck-through ones. If you keep notes on completed tasks, upgrading stops this loss before the next time that plan's list is regenerated.
- **Empty placeholder cells are no longer copied forward as if they were real notes.** A freshly scaffolded task row carries placeholder text in its notes cell; the renderer previously captured that placeholder as a real note and re-emitted it on every subsequent render. A whole-cell placeholder is now treated as empty and dropped, while a genuine note that merely contains braces mid-sentence is preserved.

### Changed

- **Nothing you author changes, and there is nothing to migrate.** This is a correctness fix to how the task-list and matrix renderers preserve your notes. No file format changes, and no manifest field is added or altered.

## [v1.12.0]

Hardening release — a train of correctness fixes across brain-stem's shipped hooks, capabilities, and installer, plus one safeguard that was inert in prior versions and is now active. Ending a session now reliably marks it closed; the multi-session overlap advisory, the memory-maintenance checks, and a library fallback that were silently no-op'ing now fire; the `install.sh --apply` upgrade preview classifies edge-case files accurately; and the auto-generated binder research links resolve. The activation: the context-pressure **Stop gate** — the "write a checkpoint before you end a long, context-heavy session" safeguard — now reads the session id it needs and enforces, where before it was dormant. A few small conveniences ride along: automatically-rendered traceability matrices, last-updated dates in the backlog (with malformed plan manifests surfaced rather than hidden), and an owning-directory column in the plan index. **Nothing you author changes and there is nothing to migrate.** See the [v1.12.0 release notes](docs/release-notes-v1.12.0.md).

### Added

- **Traceability matrices render automatically.** brain-stem can now generate a plan's traceability matrix from its manifest — the same way it already renders the task list — so the matrix stays in sync without hand-maintenance.
- **The backlog shows last-updated dates, and surfaces broken plans instead of hiding them.** Your backlog view now carries when each plan was last touched, and a plan whose manifest is malformed appears as a flagged finding rather than silently dropping off the list. New plans are stamped with a date on creation.
- **The plan index shows each plan's owning directory.** A new column marks which project or code tree each plan belongs to (for example `~/work` versus a code repo), so ownership is visible at a glance.

### Fixed

- **The "checkpoint before you stop" safeguard is now active.** brain-stem's context-pressure Stop gate — which prompts you to save a session checkpoint before ending a long, high-context session — could not read the session id it needed in prior versions and was effectively inert. It now resolves the session id and enforces. After upgrading you may see this prompt for the first time on a heavy session; running `/session-checkpoint` writes the checkpoint and clears it.
- **Ending a session reliably marks it closed.** Session close could silently fail to update the session registry in a background lock path, leaving stale "phantom" session rows. It now marks the row closed correctly.
- **The multi-session overlap advisory fires.** The advisory that warns when another Claude session is editing the same vault file could not resolve the session id and stayed silent; it now fires as intended.
- **Memory maintenance no longer silently skips.** The memory-freshness and memory-hygiene checks could quietly do nothing when run as a background job; they now run correctly, and a genuinely empty memory directory is reported loudly instead of normalized away.
- **The upgrade preview is accurate on edge cases.** When you run `install.sh --apply`, the "what will change" preview now classifies customization-overlay merges, deferred `.foundation-new` sidecar files, and files matching an older shipped version the same way the upgrade actually treats them — so the preview matches the outcome.
- **Plan-manifest dates are validated.** A badly-formatted date in a plan manifest is now caught rather than silently accepted. This is forward-looking: it flags none of your existing plans (verified across the whole corpus), and the dates it checks are auto-stamped by the scaffolder.
- **Binder research links resolve.** Dead links in the auto-generated research-index binder pages — especially for research stored in sub-folders or in non-default project homes — are fixed, and stray files misplaced inside the binder are now detected by the placement sweep.
- **An internal robustness fallback works.** A fallback that reloads brain-stem's shared helper libraries when the primary copy is missing was unreachable; it is now correct. Invisible in normal operation, but the intended safety net now functions.

### Changed

- **Nothing you author changes, and there is nothing to migrate.** The new manifest fields are optional (existing manifests stay valid), the date check is prospective-only, and the template updates affect generated files, not anything you type. The one behavior change to be aware of is the Stop-gate activation above — a dormant safeguard becoming active, not a migration.

## [v1.11.0]

Hardening release — a systematic audit of brain-stem's own self-maintenance layer (the librarian audits, the write-time hooks, and the release gates) found 80 places where a maintenance capability existed but silently failed to reach a surface it was supposed to govern — a scan that followed no symlinks, a walk rooted at the wrong directory, an owner that was never wired in. This release closes or explicitly dispositions every one of them, and caps the work with a standing **coverage guard**: a corpus of planted canary defects that proves, at every release, that each capability still detects what it claims to. Alongside the wave: note types you register yourself are now enforced at write time (not just accepted), plan status has a single source of truth, and multi-session coordination picked up a cluster of correctness fixes. **Nothing you author changes and there is nothing to migrate.** See the [v1.11.0 release notes](docs/release-notes-v1.11.0.md).

### Added

- **A standing coverage guard.** brain-stem's maintenance layer now proves its own reach. A sentinel corpus — one planted, known-bad canary per governed surface — lives in the maintainer test suite, and a new auditor verifies that every maintenance capability still detects its sentinels. That proof runs at every release, before a version reaches you; on your install the guard is wired into the full audit and session close (report-only) and reports the corpus as absent — a visible no-op, never a silent pass. Silent under-coverage (a capability that exists but never actually reaches a surface) is now a detected condition instead of an accident you discover months later.
- **Your own note types are enforced, not just legal.** Registering a custom note type (`/govern register --kind file-type`) now gives it the same write-time enforcement as the built-in types: a write missing one of its required fields is blocked immediately. The per-type contract schema ships with the foundation so the registration path validates your contract locally, and the "unknown type" message inside a work folder now explains exactly how to register a new type at the moment you need it.
- **Work spokes pick up write-time governance automatically.** A write inside any registered `~/work/<spoke>/` folder gains the full set of frontmatter and tagging rules with zero per-spoke setup; the universal `deliverable`/`reference` pair is unchanged.
- **Plans carry a machine-readable research record.** New plans scaffold a `research_artifacts[]` field in their manifest; session close populates it, so a plan's research outputs are discoverable without reading prose.
- **The plan tree's root is a closed namespace.** Stray files landing at the plan-tree root are now flagged by a placement sweep and surfaced at session start, with durable artifacts routed to where they belong.

### Fixed

- **The maintenance layer reaches everything it governs.** The bulk of this release: audits and repair capabilities now follow the vault's symlinked views through one shared walker instead of six divergent re-implementations; scans that were rooted at the wrong directory (including one that scanned zero files) are re-rooted; rename detection and cascade now reach `~/work` and `~/.claude`; missing reconcilers were built for the binder, memory, and writer surfaces; declared-but-never-wired integrations were wired; and the write-time hooks now also cover the project-binder, rules, and schema surfaces.
- **Coverage-zeroing correctness bugs.** The plan index no longer drops real rows; backups no longer wipe the per-project memory tier and now include the work tree; the handoff-disposition check receives the files it is supposed to scan; and the release gate's schema validators now fail closed when their validator is missing instead of passing silently.
- **Plan status has one source of truth.** The plan manifest is now the sole carrier of a plan's status; the spec, tasks, and brief files no longer carry a status line that can drift out of sync with it.
- **Multi-session coordination is liveness-accurate.** Session liveness is now heartbeat-authoritative with PID-liveness checks, so exited sessions no longer linger as phantom peers; and the pre-compaction checkpoint attributes work to a plan your own session actually touched, not whichever plan was most recently touched by anyone.
- **Rendering and hygiene.** Generated index tables now render as valid Markdown everywhere; reserved names are rejected at every folder-creation entry point; the human-authored header of a maintained index survives regeneration; and `--help` output was corrected across twenty-one librarian capabilities.
- **Generated task ledgers can no longer be spliced into prose.** The tasks.md renderer locates its region markers as exact whole lines now: a note that merely *mentions* the marker text in a comment renders into the real block as intended, and a file with no unambiguous block is refused with a clear message instead of being silently rewritten in the wrong place. This matters because the renderer also runs automatically after plan-manifest writes in this release.

### Changed

- **The curated hub page is retired.** The per-project binder is now fully machine-derived (the situating card and generated indexes); brain-stem no longer creates or maintains a `hub.md`, and its template no longer ships. Existing hub files are left where they are.
- **`git-hooks/` no longer ships.** The public repository no longer carries the author-side git hooks (public since an early seeding accident); they could not run in a public clone and had no adopter-facing function.
- **If you previously registered a custom note type**, its required fields now block an incomplete write where they were previously accepted silently — this is the enforcement the registration always implied. Files already on disk are untouched; the rule fires only on new writes.

## [v1.10.0]

Foundation release — a new **typed frontmatter substrate** that makes your vault navigable in Obsidian, legible to Claude, and portable to external AI tools, alongside a broad round of correctness fixes to the per-project "binder" surfaces (the auto-generated situating cards, handoff chronicles, decision logs, and lifecycle checks) and to multi-session coordination. Most of this release is internal hardening; the one new authoring-facing capability — the frontmatter cohort and its opt-in backfill — is **warn-by-default, with nothing forced on you and nothing to migrate.** See the [v1.10.0 release notes](docs/release-notes-v1.10.0.md).

### Added

- **A typed universal frontmatter cohort + an opt-in auto-fixer.** brain-stem now defines a small, consistent set of frontmatter fields for durable notes in your vault — `type`, `description`, `created`, `updated`, `tags`, `id`, and `schema_version` — so the same note is navigable for you, legible to Claude, and exportable to external AI tools (RAG/MCP) without per-tool adapters. Files created through the system are stamped automatically; existing files stay untouched until you opt in. A shipped, adopter-runnable auto-fixer backfills the fields on demand (`created` from each file's first-commit date — never today's date, a stable generated `id`, and an auto-drafted one-line `description`). The default posture is **warn, not block** — you can dial your own vault to hard-enforce once you have backfilled.
- **Obsidian Bases starter views.** brain-stem seeds Bases views that read this frontmatter, so your vault has a native, table-driven navigation surface out of the box.
- **Work-spoke folders beyond sub-projects.** A work spoke can now carry top-level folders that are not sub-projects (`--add-folder`), for reference material and deliverables that do not belong to a single sub-project.

### Fixed

- **The per-project binder surfaces are correct and bounded.** The auto-generated project "situating card" (the at-a-glance orientation for a project) is now length-bounded instead of occasionally dumping a whole file; the "handoff chronicle" (the newest-first session log) recognizes every legitimate session-heading shape and no longer drops or mis-matches entries; the decision log no longer cross-links a decision to an identically-numbered decision in a different plan; and stale "latest handoff" pointers are refreshed on write.
- **Plan lifecycle is enforced at close time.** When a project's parent is finished but a child plan is left non-terminal, brain-stem now surfaces the lag at session close instead of letting it drift silently.
- **Multi-session coordination is race-free.** When several Claude sessions run against the same vault, the shared session registry that tracks them is now updated under a single mutual-exclusion lock, so a concurrent cleanup and a registration can no longer clobber each other.
- **Governance and install hygiene.** A cluster of smaller correctness fixes: the plan-status vocabulary now has one source of truth, an empty project-parent field no longer mis-flags a plan, the release cleaner no longer over-strips adjacent text, launching from your home directory (an unsupported anti-pattern) now warns clearly, and several internal self-counting comments and manifest walks were corrected.

### Changed

- **Nothing you author changes, and there is nothing to migrate.** The frontmatter cohort is warn-by-default and the auto-fixer is opt-in; every existing file keeps working as-is.

## [v1.9.2]

Safety release — two upgrade-path fixes that stop an upgrade from overwriting state you have built up. Upgrading now preserves your registered projects (the spoke registry is seeded once on a fresh install and never reset on a later upgrade), and the project-identity migration is now shipped and rewritten so it can only rescue a genuinely-legacy plan title — it never re-stamps a plan's project identity. **Nothing about how you author your vault, projects, or plans changes, and there is nothing to migrate.** See the [v1.9.2 release notes](docs/release-notes-v1.9.2.md).

### Fixed

- **Upgrading preserves your registered projects.** brain-stem keeps a registry of the projects (spokes) you have registered. On an upgrade, that registry was being reset to the empty shipped default, so your registered projects went inactive until you restored them by hand. The registry is now seeded once when brain-stem is first installed and is never overwritten on a later upgrade, so your registered projects survive the upgrade untouched.
- **The project-identity migration can no longer re-stamp a plan's project.** brain-stem ships a one-time migration that reconciles older plans to the current project-identity scheme. It is now included in the public release (it was previously absent, so it silently did nothing), and it has been rewritten to only rescue a plan's legacy title — it never rewrites a plan's project identity. A misconfigured run can no longer reassign correctly-attributed plans to the wrong project, and if the migration is ever launched from a location brain-stem does not recognize it now says so loudly instead of proceeding silently.

## [v1.9.1]

Maintenance release — four defect and hardening fixes, all internal to how brain-stem runs. The session context-pressure reading no longer cries wolf on large-context models, the active-peer-session count no longer counts sessions that have already exited, plans numbered 100 and above can be created and graduated again, and the scheduled-job renderer now refuses to point a job's log at a macOS privacy-protected folder (which silently kills the job). **The installed foundation behaves the same in every other respect and there is nothing to migrate.** See the [v1.9.1 release notes](docs/release-notes-v1.9.1.md).

### Fixed

- **The context-pressure reading no longer reports a false ~100% on large-context models.** The session "context pressure" indicator divided usage by a fixed 200,000-token window, so on today's 1,000,000-token models it overstated how full the session was — often pinning to ~100% and triggering the mid-session checkpoint prompt when the session was only moderately full. It now resolves the true context window from the model family (1,000,000 for the current Opus / Sonnet / Fable fleet; 200,000 for Haiku), with a guard for any unrecognized model, so the percentage and the checkpoint prompt track real pressure. An explicit `CLAUDE_CONTEXT_WINDOW` override still wins.
- **The active peer-session count ignores sessions that have already exited.** Concurrent-session detection counted every registered session as "active," including ones whose process had already died or was never recorded — so the "N active peer sessions" notice, and the file-overlap warnings built on it, were inflated. Sessions are now liveness-checked by process ID: dead and unrecorded rows are filtered from the count and reaped from the registry, so the number reflects sessions that are genuinely running.
- **Plans numbered 100 and above can be created and graduated again.** The plan-slug pattern accepted only a two-digit number prefix, so creating or graduating a plan numbered `100-…` or higher was rejected. The pattern — and every place that re-checks it — now accepts two-or-more digits. *(Reaches most adopters only once they pass 99 plans; restores the intended behavior.)*

### Changed

- **Scheduled jobs fail loudly instead of dying silently on a privacy-protected log path.** On current macOS, a launchd job whose log file lands in a privacy-protected folder (Desktop, Documents, Downloads, iCloud Drive) cannot start — it aborts before running, with no output. The scheduled-job renderer now refuses to emit such a job and fails at render time with a clear error, and a release-time gate enforces the same rule on the shipped templates. The shipped templates already log to a safe location, so nothing changes for a standard install; this is a guard against a misconfigured log path. *(Hardening; no adopter action.)*

## [v1.9.0]

Feature release — brain-stem now **self-orients at the start of a session**. When you open a session inside a registered work project (`~/work/<project>`) or against a plan's binder, brain-stem regenerates a short **situating brief** from the current state on disk and hands it to the assistant at startup, so it orients itself before you type anything. The same release makes each work project's `CLAUDE.md` a thin identity file with an **auto-maintained map of the project**, gives a work project's folders **self-maintaining indexes**, and creates a project's binder cover page **at registration** (previously the assistant was pointed at a page that was never minted). Everything is additive, automatic, and never writes into your authored content. See the [v1.9.0 release notes](docs/release-notes-v1.9.0.md).

### Added

- **A self-orienting session start.** Launch a session inside a registered work project or against a plan binder and brain-stem resolves where you are, regenerates a small situating brief from disk, and force-feeds it to the assistant at startup. The brief carries only machine-derivable orientation (what the project contains, what is active, the latest handoff headline, where to look next); the curated, judgement-bearing pages stay read-on-demand. It is regenerated every session, so it is never stale, and kept small so it costs almost nothing to load.
- **A binder cover page that is minted at registration.** Registering a project or plan now creates its binder cover page up front, instead of pointing the assistant at a page that was never created.
- **`work-map-generate` — a self-maintaining project map.** A work project's `CLAUDE.md` is now a thin identity file plus an auto-maintained map of the project's folders, regenerated from what is actually on disk. The map block is clearly marked as generated; anything you have added to that file yourself is left in place.
- **`work-index-maintain` — self-indexing folders.** Inside a work project, the `deliverables/` and `reference/` folders (and each sub-project's own folders in a master project) now grow and keep their own `_index.md` listings automatically.
- **Automatic upkeep with no command to run.** The situating brief, the project map, and the folder indexes are refreshed automatically — when a session ends, when the next one starts, when you register or grow a project, and when a plan's tracking file is written.

### Changed

- **A work project's `CLAUDE.md` is collapsed to identity + an auto-maintained map.** It no longer carries a hand-maintained project map or a plan roster; the map is derived from disk and kept current for you. Projects registered before this release are left untouched — the new shape applies to projects you register from here on.
- **Generated vs authored content is treated distinctly.** brain-stem generates and keeps current the parts a machine can derive correctly (the project map, the situating brief, folder indexes) and never machine-writes the parts that need judgement (your cover pages, notes, and deliverables). Generated files are marked as such and confined to the project's own scaffolding.

## [v1.8.0]

Feature release — brain-stem now governs the **work projects** you keep under `~/work/` (surfaced as the `Work/` view in your vault), and the same release makes session-close **commit-free**. A folder you create inside `Work/` can now be turned into a fully-governed project workspace with one command, so the highest-stakes, most client-facing content surface is governed with the same markdown discipline as the rest of your vault — and a project authored from outside the vault (`cd ~/work/<project>`) is governed too, not just one opened from inside Obsidian. Separately, `/librarian session-close` no longer commits or pushes your vault as a side-effect, and sessions that end without a formal close now get an automatic, commit-free integrity pass. See the [v1.8.0 release notes](docs/release-notes-v1.8.0.md).

### Added

- **`/govern register --kind project` — a one-command project workspace.** Run it from inside a folder under `~/work/` and brain-stem mints a governed project: by default a six-file flat workspace (`CLAUDE.md`, a `hub.md` cover page, a `README`, an `updates.md`, and `deliverables/` + `reference/` folders). Pass `--layout master --first-sub <name>` instead for a master project whose organizational sub-projects each own their own `README`/`deliverables`/`reference`. From that point on every write into the project is governed — file types, placement, and tags are checked the same way they are everywhere else in your vault.
- **Governed writes from outside the vault.** A deliverable authored from a project launched directly on disk (`cd ~/work/acme`) now reaches the same governance the vault view receives: brain-stem maps the physical `~/work/<project>/…` path to its `Work/<project>/…` vault view before checking it, so the launch location no longer decides whether your work is governed. This only happens for projects you have registered; an unregistered `~/work/` scratch folder is left alone.
- **A `project` tag dimension.** Tags like `#project/acme` are now first-class, user-facing vocabulary — uncapped, because a project name is an identifier, not a category — so you can tag and filter work by project without tripping a tagging advisory.
- **Project-associated vault writers.** A vault writer (a system that writes notes into your vault on your behalf) can now be tied to a project: register it with `--project`, and it gains a `Project` column in the writers catalog plus two health checks that flag a writer pointed at a project that does not exist or one whose destination has drifted off its own project.
- **Sub-project growth and promotion.** A master project grows with `--add-sub <name>`; a sub-project that outgrows its master is promoted to a top-level project of its own with `--adopt`, which moves it and gives it its own `CLAUDE.md` and cover page without disturbing the content already inside it.
- **An automatic integrity pass when you forget to close.** A session that ends without a `/librarian session-close` now gets the integrity subset of the close run automatically, in the background: indexes are refreshed, conventions re-checked, and plan-drift detected, so your vault stays honest without depending on you remembering to close. It runs on a graceful exit and is backstopped at the next session start to catch crashes and terminal-closes. It is detached, advisory, and — like the manual close — never commits, never pushes, never applies a rename, and never writes into your vault.

### Changed

- **`/librarian session-close` no longer commits or pushes.** The backup step was removed from the close chain, so the close is now structurally commit-free — it re-checks conventions, refreshes indexes, re-syncs plans, and dry-run-cascades renames, but never runs `git commit` or `git push`. This makes the `SECURITY.md` promise that backup runs "by hand, never automatically" literally true. A *manual* close now **offers** `/librarian backup` after the chain ("N files changed; run `/librarian backup`?") instead of committing for you; the automatic integrity pass never offers and never commits. **If you relied on a manual session-close to back up your vault, run `/librarian backup` yourself afterward.**
- **One project, two shapes.** Every top-level `Work/` folder is one project. A *flat* project keeps its deliverables and reference material at the top; a *master* project keeps none at the top and instead organizes its work into sub-projects. A sub-project is an organizational unit, not a second kind of project — it has no `CLAUDE.md` and is not its own launch context; you launch from the master and promote a sub to top-level with `--adopt` if it needs one of its own.

### Upgrade note

- **Work-project governance is additive.** If you do not keep work under `~/work/`, nothing changes — the `Work/` surface and project governance only activate once you register a project, and an unregistered `~/work/` folder is never touched. The new project tag, the writer `Project` column, and the new health checks are all inert until you use them.
- **The session-close contract change affects everyone who closed manually.** After upgrading, a manual `/librarian session-close` will no longer push your vault to your remote; it offers `/librarian backup` instead. Nothing is lost — your notes and the close's own work are still on disk — but if your habit was "close the session and it's backed up," replace it with "close the session, then run `/librarian backup`."

## [v1.7.0]

Maintenance release — the foundation no longer seeds the in-vault `System Governance/` folder, the eight-file narrative-spoke seed that explained each governance pillar inside your vault. That narrative is published in full on the documentation site, so the in-vault copy was a drift-prone duplicate that also blurred the line between what the foundation owns and what you own. **Upgrading adopters are unaffected:** a folder an earlier version already seeded is never touched — it becomes ordinary, user-owned content — and nothing is pruned out from under you. See the [v1.7.0 release notes](docs/release-notes-v1.7.0.md).

### Removed

- **The seeded in-vault `System Governance/` folder** is no longer created by vault setup. The per-pillar governance narrative it held (naming, tagging, frontmatter, mandatory files, file-type contracts, doc-dependencies, plus its index) lives in full on the documentation site — the *governance engine* and *vault governance* pages carry the complete write-up, so no explanation is lost.

### Changed

- **The "this is a brain-stem vault" marker moved.** brain-stem recognizes a vault it built by looking for a small marker file; that marker used to be the `System Governance/` index page and is now `Vault Writers/_index.md`, a page setup already creates. This is invisible in normal use — it only ensures that re-running setup on a vault brain-stem already built is still recognized.
- **A legacy `system-governance-spoke` file type now gives a clear retired-type message.** If you keep and edit one of the old seed pages while it still declares `type: system-governance-spoke`, the governance check recognizes that type as retired and says so directly — a plain retirement note, not an "unknown type" error or a hard failure.

### Upgrade note

- Your already-seeded `System Governance/` folder is never touched — upgrading does not re-run vault setup, so it stays exactly where it is and quietly becomes user-owned content you may keep, edit, or delete. One inert leftover may remain: brain-stem keeps a copy of the seed files inside your install directory (`~/.claude/vault-init/`), and the upgrade engine delivers managed files but does not prune ones removed upstream, so an inert `vault-init/System Governance/` set may persist under your install directory. Nothing reads it at runtime; it is harmless residue you can leave or delete.

## [v1.6.1]

Documentation release — the published documentation is brought back into step with the system as it ships after v1.5.0 and v1.6.0. **The installed foundation is unchanged and there is nothing to migrate.** The command reference gains the `/deliver-export` command (shipped in v1.5.0 but never documented), the vault tour now describes all five setup shortcuts (the `Work/` surface was missing), several "what changed" cross-links are repointed at the current release, and a leftover reference to a removed ingestion script is cleaned up. See the [v1.6.1 release notes](docs/release-notes-v1.6.1.md).

### Changed

- **The command reference now documents `/deliver-export`** — the v1.5.0 command that exports a finished `Work/` deliverable to a shareable `.docx` or PDF. It was working but undocumented; the count of commands you run directly is now ten.
- **The vault tour describes all five setup shortcuts.** The architecture and onboarding pages said setup wires "four" convenience links (`Plans/`, `Skills/`, `Wiki/`, `Projects/`) and omitted the `Work/` shortcut added in v1.5.0; they now say five and list it.

### Fixed

- **Stale documentation cross-links.** Getting-started and migrations pages linked older release notes as if current; they now point at the current release. A leftover "ingestion script" reference in the command reference is reworded to reflect only what ships. *(Documentation only; no adopter action.)*

## [v1.6.0]

Maintenance release — the `meeting-note` file type and its contract are removed from the installed foundation, and the release pipeline gains a deletion-prune arm so files dropped from the foundation actually leave the published tree. This **supersedes the v1.5.0 note that "the `meeting-note` file type and its rules are unchanged and still ship"**: v1.5.0 removed the empty `Meetings/` seed folder and the ingestor, and v1.6.0 completes that demotion by moving the type, contract, and governance out of the foundation entirely (parked, re-providable later as an overlay archetype). The universal historical-data write warning still applies to date-named notes. See the [v1.6.0 release notes](docs/release-notes-v1.6.0.md).

### Removed

- **The `meeting-note` file type and its contract** are no longer part of the installed foundation. Its governance is withdrawn — the frontmatter type entry (including the Granola workflow fields), the body-shape contract, the `Meetings/**` folder exemptions, the `Meetings/` known-root, and the doc-dependency fan-in. The standalone contract is preserved out-of-foundation for a future meeting-oriented add-on. This reverses the v1.5.0 "still ships" note and finishes the `Meetings/` demotion v1.5.0 began. Date-named notes still receive the universal historical-data write warning by default, so no write-safety is lost.

### Changed

- **The librarian's required-field check now reads the composed governance bundle directly** instead of a hand-maintained mirror. This fixes a latent gap in which the `reference` (knowledge-library) type's required fields were not actually enforced; `reference` articles now validate against their declared required fields.

### Fixed

- **The release pipeline now propagates deletions.** When a file is dropped from the foundation, the dev→ship transform prunes it from the published tree, and a new tree↔manifest completeness gate fails the release if any shipped directory carries a file the manifest does not — closing the durability gap that previously let a removed file linger as a stale shipped artifact. *(Maintainer-facing; no adopter action.)*

### Upgrade note

- After upgrading, a stale `meeting-note.md.json` contract file may remain under `~/.claude/governance/file-type-contracts/`: the upgrade engine delivers and updates managed files but does not yet prune ones removed upstream. It is inert (no shipped type references it) and safe to delete; an automatic removed-member prune is tracked as a follow-on.

## [v1.5.0]

Feature release — a new **work / deliverable context layer**. brain-stem gains a fourth first-class context surface, `work/`, alongside your projects, wiki, and plans: a home for deliverable-centric, often non-code work (briefs, memos, reports, decks authored as markdown) governed with the same markdown discipline as the rest of the vault. The release adds the `deliverable` file type, a thin Markdown→DOCX/PDF export skill, and a documented extension-seam contract so archetype add-on packages (consulting, design, PM) can layer specialized structure on top **without modifying the foundation**. As part of the same change, three unrendered placeholder templates and an unused meeting seed folder plus its ingestor are removed from the installed foundation. See the [v1.5.0 release notes](docs/release-notes-v1.5.0.md).

### Added

- **A `work/` context surface.** A new recommended parent for deliverable-heavy, non-code work, resolved like the other roots (environment override → manifest → `~/work` default) and surfaced into your vault as a `Work/` view. Each `work/` spoke gets its own per-spoke memory automatically, and a new `Deliverables` block on the spoke's `hub.md` joins it to the binder on the shared `project:` slug.
- **A `deliverable` file type.** A universal, archetype-neutral vocabulary for deliverables — a thin lifecycle contract governing frontmatter only (`status: draft → delivered → superseded`, `audience: internal | external`) with a free-form body, so a one-page brief and a forty-page report share one type without a forced structure.
- **A `deliver-export` skill.** A content-agnostic Markdown → DOCX / PDF exporter (Pandoc, with a slot for a branded reference document). Markdown stays the single source of truth; exported binaries are write-once and never committed or round-tripped.
- **A documented extension-seam contract.** A binding description of the four seams (folder scaffolding, overlay governance, starter templates, recipe composition) an archetype add-on package uses to extend the `work/` layer without editing the foundation, with a generic `project-workspace` add-on as the reference proof.

### Changed

- **`audience` vocabulary is archetype-neutral.** The base `deliverable` type ships `audience: internal | external`; specialized values such as `client` are added by an add-on package as an overlay refinement, keeping the foundation vocabulary universal.

### Removed

- **Three unrendered placeholder templates** (`prd`, `context`, `updates`) are no longer installed into the foundation — they were placeholder files with no shipped renderer. They now live in the `project-workspace` add-on, which seeds them as named starters on request.
- **The empty `Meetings/` seed folder and the meeting-note ingestor** are removed from the installed foundation. The `meeting-note` file type and its contract are unchanged and still ship; only the empty seed folder and the ingestor script (preserved for a future meeting-oriented add-on) are removed.

## [v1.4.0]

Documentation release. **The installed foundation is unchanged — there is nothing to migrate.** This release rebuilds the public documentation into a complete, navigable site: a rich front-door README, a new `SECURITY.md`, a full command reference, an FAQ, a global glossary, a five-minute quickstart, a version-migrations guide, a standalone uninstall how-to, a claude-mem page, and a design-decisions overview — plus the "Why brain-stem" keystone and the context-library architecture pages, every architecture page reframed as native→gap→enhancement and closed with its own evidence section, and an explicit ordered site navigation. See the [v1.4.0 release notes](docs/release-notes-v1.4.0.md).

### Added

- **A new `SECURITY.md`** documenting the scope of trust (local-only, no network egress), the install/overwrite surface, the vault-write blast radius, and the private vulnerability-reporting channel.
- **A reference section** — a command reference for every command brain-stem adds, a global glossary, and an FAQ.
- **New getting-started pages** — a five-minute quickstart, a version-migrations guide (what each release moves for you), a standalone uninstall how-to, and an optional-claude-mem page.
- **A "Why brain-stem" keystone** and a **"Design decisions"** overview that make the platform-completion case and map every load-bearing choice to its evidence.
- **Context-library documentation** — a context-and-memory umbrella page and a context-library deep-dive for the three-surface model shipped in v1.2.0.

### Changed

- **The README is now a rich front door** — value proposition, install, and a capability map that mirrors the docs, with depth delegated to the published site.
- **Every architecture page** opens with a native→gap→enhancement frame and closes with a self-contained "Why this design — evidence & alternatives" section citing durable external sources.
- **Site navigation is now explicit and ordered** (Home → Why brain-stem → Getting started → Architecture → Reference → Design decisions → Release notes), and the documentation build is pinned to the Material 9.x line.

## [v1.3.0]

Maintenance release. brain-stem now writes **zero machine files into your vault**. The assistant's operational exhaust — run logs, the session-close receipt, the librarian's working manifest, and internal hook state — moves out of the vault (and out of the `~/.claude` config home) into the standard per-user **state directory**, `~/.local/state/brain-stem`, following the XDG Base Directory specification. The vault's `Logs/` folder is retired: your vault is now 100% human knowledge, with nothing machine-emitted leaking into Obsidian search or the local graph. See the [v1.3.0 release notes](docs/release-notes-v1.3.0.md).

### Changed

- **The vault holds only human knowledge.** brain-stem no longer ships or writes a `Logs/` folder into your vault. The session-close receipt, the librarian's working manifest, cron and orchestrator run-logs, and live hook state now resolve under `~/.local/state/brain-stem/` (in `logs/`, `manifests/`, `hooks-state/`, and `runtime/`). Obsidian search and the local graph now see only the notes you and the assistant write — never machine output.

- **Operational exhaust follows the XDG state convention.** Logs and persistent working state resolve under `$XDG_STATE_HOME` (default `~/.local/state`), the standard home for disposable per-tool state. The durable data tier (`~/.local/share/brain-stem`) and the install/uninstall record (`~/.claude/logs`) are unchanged.

### Fixed

- **Two internal path inconsistencies resolved.** The librarian's coordination lock and its working manifest now resolve to the same place its readers look, and the write-time audit log's writer and reader now agree on one location — closing two long-standing cases where a writer and a reader had drifted onto different paths.

## [v1.2.0]

Feature release. brain-stem now has a **three-surface context library**: a shared **library** of durable, reusable knowledge that any project can draw on; per-project **binders** that gather a project's research, decisions, and hand-offs into living index pages; and a **workshop flow** that nudges you to check the library before starting fresh research. The librarian gains the capabilities that keep all three surfaces current, and a new file type governs the library articles themselves. See the [v1.2.0 release notes](docs/release-notes-v1.2.0.md).

### Added

- **A shared knowledge library.** A new `_library/` area holds durable, reusable articles — one concept per file, written in general terms so they apply across projects rather than to a single piece of work. Each article carries a one-line "when to read this" so a reader can tell at a glance whether it is relevant. A library index lists every article by topic, and a running change log records what was added or revised, so the library stays browsable as it grows.

- **A new "reference" file type for library articles.** Library articles are governed by their own contract: one concept per file, a required routing one-liner, and a size budget that keeps an article readable. The index pages read that routing line first when deciding how to describe an article. Templates for an article and a topic index ship with the install.

- **Project binders.** Each project now gets three living index pages — a research index, a decision log, and a hand-off index — that gather the project's scattered notes into one readable place per kind. The librarian regenerates them from what is actually on disk, so they never drift from the underlying files, and a hub page ties them together. Binder and index templates ship with the install.

- **Librarian capabilities for the three surfaces.** Six new librarian capabilities keep the surfaces current: a library index builder, a promotion step that lifts a project note into a scrubbed, reusable library article, a library change-log rotator, and the three binder builders (research, decisions, hand-offs). They regenerate from disk and never invent content.

- **Workshop hooks.** Three hooks wire the flow together: a session-close step that appends a one-row chronicle entry for the session, a library change-log appender, and an advisory pre-research check that, before you start new research, points you at any library article that already covers the ground. The pre-research check only advises; it never blocks.

### Changed

- **The library index understands light topics.** A topic index page adapts its layout for a small or single-type topic, and the index contract now states that adaptation explicitly — fewer than three articles **and** fewer than three distinct types reads as a light topic — so the generated pages and the contract agree.

### Fixed

- **A parent-plan resolver no longer mistakes a correct self-reference for a loop.** A plan file that correctly points at its own top-level plan was being misread as a circular reference and flagged as an error. The resolver now recognises a legitimate self-pointer and only reports genuine cross-plan loops.

## [v1.1.4]

Feature release. brain-stem now keeps a running **episodic record of your sessions** and adopts a **pointer-based shape** for the long-lived memory that survives between sessions. The memory index stays small and readable; the bulky detail lives in a chronicle file and in your vault, referenced by a single line. See the [v1.1.4 release notes](docs/release-notes-v1.1.4.md).

### Added

- **A session chronicle.** When a session ends, brain-stem now prepends a one-row, newest-first entry to `memory/episodic-chronicle.md` — the session's anchor, what it touched, its hand-off and resume pointers, and a one-line summary. `MEMORY.md` carries a single pointer line to that chronicle instead of a growing pile of per-session files. The chronicle is harvested without calling a model (no token cost at session end), rotates to a dated archive when it crosses ~50 KB, and never deletes rows. The one-line summary is filled in at session-close from the hand-off you just wrote.

- **A pointer-currency check.** A new librarian capability runs at session-close and reports any plain-text absolute-path pointer — in `MEMORY.md`, a memory topic-file, or a `rules/*.md` file — that no longer resolves on disk. It is advisory and propose-only (it never edits or blocks), and it is change-gated: it stays silent unless one of those files actually changed since the last scan, so it does not train you to ignore an always-on "all clear."

- **A memory-pointer placement advisory.** The write-guard now warns (never blocks) when a pointer line in `MEMORY.md` would land below the read-fold — past line 200 or the byte cap — where the loader would not see it on a normal read.

### Changed

- **Memory uses a documented pointer shape.** `MEMORY.md` and the seeded `rules/` README now describe a "vault-pointer shape" — an absolute path, an imperative read-instruction, and a short why — for referencing a large external file instead of inlining it. This keeps the always-loaded index lean while still pointing at the full detail.

- **The rules README documents a known upstream limitation.** User-scope `~/.claude/rules/` glob scoping is silently non-functional upstream (GitHub `#21858` / `#25562`); project-scope `.claude/rules/` is reliable. The seeded README now says so, and a broken in-repo documentation link was repointed at the public memory docs.

- **Documentation corrected.** The memory-model doc no longer cites a fabricated decay statistic (it states the corroborated signal-to-noise point instead), and a librarian capability-status note that overstated what is wired was split into two accurate statements.

### Fixed

- **A legacy install's old episode files are migrated, not orphaned.** Upgrading moves any pre-existing `memory/episode_*.md` files into `memory/episodic-legacy/` so they leave the flat memory glob (and stop being re-indexed) without being deleted. A fresh install does nothing here; the migration is idempotent.

## [v1.1.3]

Maintenance release focused on the in-place upgrade path for existing adopters, plus the runtime-config and session-continuity fixes staged after v1.1.2. See the [v1.1.3 release notes](docs/release-notes-v1.1.3.md).

### Fixed

- **Upgrading over a `~/.claude/.gitignore` you already had no longer loops forever.** `.gitignore` is delivered by a three-way merge (your own ignore rules are preserved, the brain-stem block is appended), so on any home with a pre-existing `.gitignore` the merged file legitimately differs from the pristine template. The delivery-verification step treated that difference as an under-delivery, refused to stamp the install (exit 56), and — because the merge is idempotent — every re-run hit the same wall. Merge-delivered files are now exempt from that check, so the upgrade converges and stamps on the first pass.

- **Skipping a version on upgrade now delivers every prior-release floor.** Upgrading directly across a version (for example v1.1.1 → v1.1.3 without stopping at v1.1.2) left out the prior release's baseline record — a file the newer install references — which then tripped the same delivery-verification refusal (exit 56). The upgrade engine now enumerates everything the new version ships, not only what the older install already had, so a multi-version jump delivers the complete set and converges.

- **Session checkpoints are written and read from the same place.** The checkpoint writer and the hooks that read it resolved different default directories, which could fire a false "stale checkpoint" stop-block. Both now resolve the one canonical session-state root, and the missing checkpoint-pressure writer was added.

- **Dead and mislabeled configuration knobs cleaned up.** Several manifest settings were documented as live but read from nothing (or from environment variables never set); the genuinely-unused ones were removed and the rest are now actually wired (environment → manifest → default), so the documented knobs match what the code does. The user-manifest schema was also reconciled with what the path/vault/behavioral resolvers actually read, so a manifest that exercises those knobs no longer fails validation.

- **Fresh installs now deliver all 12 adopter schemas.** Three schemas (`memory-schema`, `rules-schema`, `review-queue-schema`) are resolved at runtime by installed helpers, but the installer's schema list had not grown to include them — so every fresh install since v1.1.2 was missing those three files. The affected helpers degrade gracefully when a schema is absent (falling back to built-in defaults), so this was a latent completeness gap rather than a failure; the installer now ships the full set, so the schema-driven validation paths are actually live.

### Changed

- **The upgrade dry-run shows every blocker in one pass.** Pre-flight gates that used to stop on the first problem now aggregate: a single `bash install.sh` preview lists every required override together, and the genuine must-stop safety conditions (an unset `CLAUDE_HOME`, or a vault symlinked under the install target) are surfaced in the same preview under a separate, non-waivable findings list — so you can see and resolve everything before committing to `--apply`.

- **The getting-started and upgrade runbook is now copy-paste runnable end to end.** The upgrade section now shows the required `export CLAUDE_HOME`, documents `--retrofit-existing` (for a home that already has plans) and `--backup-dir` (required on an upgrade that replaces your merged `settings.json`), adds a note for clones made before the one-time public-history rewrite (`git fetch origin && git reset --hard origin/main`, or re-clone), and links the current release notes.

- **The `/librarian full` sweep is documented honestly.** The skill doc now enumerates what `full` runs and states plainly that the plan-tree index files (`_index.md`, `_backlog.md`, `_archive.md`) are written lazily on the first relevant librarian run — they are not seeded at install — so a brand-new plans folder legitimately has none of them until then.

- **The release pipeline now produces a byte-reproducible manifest, and the baseline-freeze guard is stronger.** The shipped manifest's build tools are now propagated into the published tree so its `generated_at` is pinned to commit time (identical across rebuilds), and the guard that keeps every superseded release's baseline frozen now checks the complete expected set rather than only the files that happen to be present — so a deleted floor is caught instead of passing silently.

## [v1.1.2]

Maintenance release. Every functional governance value is byte-identical to v1.1.1 — but this release carries several install-correctness and data-safety fixes beyond the original executable-bit repair, and clears internal build-process shorthand out of the public governance artifacts. See the [v1.1.2 release notes](docs/release-notes-v1.1.2.md).

### Fixed

- **Core hooks and librarian capabilities now ship executable.** Two shipped scripts had lost their executable bit, so they silently failed to run after installation: the **governance write-guard hook** (`pre-write-guard`, which `settings.json` invokes by path — a non-executable hook fails outright, leaving writes unguarded) and the **note-placement checker** (`placement-validate`, which session-close skips when it is not executable). Both are restored; the installer now re-applies the executable bit to every hook and librarian capability after copying them; session-close now reports a shipped-but-non-executable capability as an **error** rather than silently treating it as "not installed"; and the pre-tag release gate asserts the executable bit across the whole managed set — so a hook or capability can no longer silently no-op on an install.

- **Librarian capabilities that read the plans and vault-writers governance rules now run on a standard install.** Several capabilities — including backlog indexing, plan archiving, task rendering, and vault-writer reconciliation — read values from governance pillars that are *composed into* the shipped governance master rather than delivered as separate files. On a normal install those separate files aren't present, so the capabilities exited early instead of running. They now resolve the effective values from the shipped governance master, so they work on a clean install.

- **Vault-writer reconciliation no longer risks dropping your edits.** A configuration-shape bug left the reconciler's survivorship setting empty, which silently bypassed the "your edits win" preservation step — so a reconciliation pass could overwrite manual edits. The setting is now read correctly and the preservation step always applies.

### Changed

- **The public governance artifacts read in plain product language.** The shipped governance schema, index, and composed master carried internal build-process shorthand in their descriptive text. Those descriptions now name the product directly — the per-pillar `_rules[]` register, the `home`/`category` rule model, and the v2 pillar structure. This is a description-only change: every functional governance value (types, exempt paths, tag cap, taxonomy) is byte-identical to v1.1.1.

- **Governance is now read through a single merged view.** Every hook and capability that reads governance now resolves it through one merged view — the shipped foundation values, with an optional per-vault overlay layered on top — instead of reading individual rule files directly. For a standard install with no overlay the effective values are identical to v1.1.1; the change makes resolution consistent across the whole system and lays the groundwork for per-vault governance overlays.

- **A post-write verification hook is now active, and the status line is recoverable.** A verify-after-write check that shipped in earlier releases but was registered nowhere is now wired to run after edits; and the installer's hook reconciler can now restore the status-line command if a local settings file had overridden it.

## [v1.1.1]

Patch release. Makes the in-place upgrade engine actually deliver its fixes to **legacy adopters** — every install made before v1.1.0 introduced the version stamp. In v1.1.0 the per-file delivery path covered the hook, schema, template, and governance-scalar files, but a second copy path that ships whole directories (skills, the orchestrator, the installer support files, and the vault seed) silently skipped any file that already existed on a legacy install. The result: 18 changed files stayed at their old version even after re-running the upgrade. v1.1.1 closes that gap. Re-run `install.sh` from the updated source — see the [upgrade runbook](https://peter-tiktinsky.github.io/brain-stem-docs/installation.html) and the [v1.1.1 release notes](docs/release-notes-v1.1.1.md).

### Fixed

- **The whole-directory copy path now delivers on a legacy install.** The install steps that ship the skills, orchestrator, installer support files, migrations, file-type contracts, and vault seed previously used a copy mode that skipped any file already present — so on an install made before the upgrade engine existed, those files never updated. They now route through the same per-file engine the rest of the upgrade uses, so every changed file is delivered (including the eleven managed files whose paths contain spaces, which the directory copy also dropped).
- **The upgrade refuses to declare success if delivery fell short.** Before writing its completion stamp, the installer now verifies that every managed file it shipped actually reached the new version. If any file is still stale, it stops with a non-zero exit, writes no completion stamp, and does not advance its baseline — so a half-delivered home is never recorded as a finished upgrade. Simply re-running converges it.
- **A home that already ran the broken v1.1.0 self-heals.** An install that ran v1.1.0 was stamped as up to date while 18 files were still stale underneath. On v1.1.1 those pristine-but-old files are recognized as a known prior release and updated cleanly, instead of being mistaken for files you had edited and set aside as `<file>.foundation-local`.
- **The upgrade preview tells a legacy adopter the truth.** Running `bash install.sh` over an existing install used to fail with an error and print no plan. It now exits cleanly and prints an honest, write-free preview of exactly which files the upgrade would change.

## [v1.1.0]

In-place upgrades. Re-running `install.sh` over an existing install now upgrades it — detecting the installed version, applying only what changed, preserving your edits, and rolling back atomically on failure. Previously brain-stem was fresh-install only; adopters whose files go through the per-file delivery path receive fixes by re-running the installer.

### Added

- **In-place upgrade engine.** `install.sh` detects an existing install via a version stamp and performs a per-file upgrade instead of refusing or clobbering. Files delivered through the per-file path — hooks, schemas, templates, and the individual governance rule files — are compared by content hash against both the previous release and the new upstream: unchanged files are skipped, genuinely-updated files are applied, and a file you edited is updated to the new version with your bytes preserved alongside as `<file>.foundation-local`. A second path ships whole directories (skills, the orchestrator, the installer support files, the vault seed); on an install made before this version stamp existed, that path skipped any already-present file — fixed in v1.1.1. `--upgrade` makes the intent explicit; a downgrade or major-version jump is refused.
- **Atomic apply with rollback.** Every upgrade stages and validates each file before an atomic rename and journals each change; any mid-apply failure restores every already-applied file in reverse order — the upgrade is all-or-nothing.
- **Dry-run upgrade preview.** Preview exactly which files an upgrade would add, replace, or leave untouched before applying.
- **Forward-only migrations.** An idempotent migration runner applies any version-to-version state transforms once, tracked by a high-water mark.
- **Per-release manifest archive** under `governance/baselines/` — the per-version file-hash floor the upgrade engine reconstructs from, minted at each release cut.

### Fixed

- A broad set of fresh-adopter defects surfaced by an end-to-end install audit, across onboarding capture, the governance and vault guards, session-close, backup secret-hygiene, and the uninstaller:
  - The write guard, frontmatter enforcement, and the placement/staleness checks no longer error or mis-fire on a fresh adopter who has not configured a vault.
  - On the per-file delivery path, upgrades apply files whose paths contain spaces. (The whole-directory copy path still skipped pre-existing files on a legacy install in this release — corrected in v1.1.1.)
  - Backups scan for and exclude credential-shaped secrets before committing, and report deletions and push failures honestly.
  - `uninstall.sh --force-remove` preserves your own content and tolerates install paths that contain spaces.
  - Onboarding identity discovery falls back across git config, environment, `gh`, and the OS instead of giving up when global git identity is unset.

## [v1.0.2]

The plan tree's home directory is now created at install time, so plan commands work immediately after install — before onboarding.

### Changed

- `install.sh` now creates the plan-tree home (`~/.claude-plans` by default) during `--apply`, instead of deferring it to first-run onboarding. The directory is created outside `~/.claude/` (clear of the sensitive-file gate) and is declared in the install preview.

### Fixed

- `/new-plan` and the inbox-promotion helper now create the plan-tree root if it is missing — and `/new-plan --dry-run` previews without writing — instead of erroring when the root does not yet exist.

## [v1.0.1]

Patch release. Fixes a critical fresh-install regression in the default-on hook set that made v1.0.0 unusable for new adopters.

### Fixed

- `pre-write-guard` denied **every** Edit/Write on a fresh install: an empty default for the dead-plans-path tripwire made the guard match every absolute path. The guard now activates only when that tripwire path is actually configured.
- `pre-write-guard` sourced its plan-path helper from a stale (pre-relocation) location, aborting the hook under `set -euo pipefail` on a fresh install.
- `stop-drift-scan` referenced an unresolved governance-bundle path under `set -u`, crashing the hook at session stop on a fresh install.

### Added

- A clean-room runtime smoke-test that fires every default-wired hook on a fresh install and asserts the write guard allows a benign write — wired into the install-verify gate so this class of regression is caught before release.

## [v1.0.0]

First tagged release of brain-stem: a macOS-only, single-user personalization layer for Claude Code. Consolidated governance substrate, default-on hook set, onboarding flow, and the install/uninstall machinery. Fresh-install only.

### Added

- Initial public release.
