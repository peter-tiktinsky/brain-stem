# Release notes — v1.19.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.19.0 is a large minor release that ships two automatic upgrade-time migrations.** A migration is a self-contained, idempotent step that runs during a normal upgrade and converges your existing installation to the new state; you do not run it by hand, and running it twice changes nothing the second time. Both migrations remove something brain-stem no longer ships, and this page says what each removes and what it never touches. Five threads: **the installer seeds no rules any more**, and `rules-compact` is retired; **every inbox capture is decided when it is made**; **the plan folder becomes a managed set** with one research path from staging to Library promotion; **hand-run procedures become named commands** with documented exit codes; and **the guards fail visibly**, from checkpoint banners to a default deny on editing an installed file. The shipped tree grows from 281 to 312 files.

---

## The headline — brain-stem seeds no rules

Claude Code loads every markdown file in your global rules directory (`~/.claude/rules/`) at the start of every session and every subagent spawn. Until now the installer wrote four always-on entries there: the project-binder pointer, the pre-research library check, the work-project registration on-ramp and the durable-artifact routing convention, each paid for on every launch.

**The installer now writes nothing there and creates no rules directory**, which holds only rules you write or promote from memory. Each former seed's guidance is delivered by a shipped hook, at the moment it applies:

- **Project-binder pointer** — `hooks/session-start-project-context.sh` injects the project's situating card at session start.
- **Pre-research library check** — `hooks/pre-research-check.sh`, a required per-message hook, injects Library coverage when your request looks like research.
- **Work-project registration** — the write guard `hooks/pre-write-guard.sh` raises a `[WORK SPOKE]` advisory on the first write under an unregistered `~/work/<spoke>/`.
- **Durable-artifact routing** — the same guard names the capture and graduate commands when it denies a plans-root write, and flags a Library article that is not universal.

**To see what now delivers a retired rule**, run `/librarian rules-hygiene --compare-retired <rule>`. It prints the rule file beside the shipped hook that carries its guidance (exit 0 done, 2 refused, 3 the carrier is missing). A companion mode, `rules-hygiene --check-load <rule>`, answers whether a path-scoped rule actually loaded, from the instructions-loaded log (exit 0 loaded, 1 not loaded, 2 refused, 3 no log).

**`rules-compact` is retired.** The v1.18.0 capability that compacted a hook-backed rule to a stub is gone, with the `enforced_by` field it wrote into the rules schema. Instead, `rules-hygiene` reports a rule whose body names a shipped blocking hook as an informational `hook-redundant` finding and leaves the decision with you.

**Promotion never overwrites a rule.** `memory-globalize` now refuses when the target rule file already exists and reports `promotion-blocked`; `--replace` overrides it on an attended run only.

---

## The two migrations — what each does, and what it will never do

**`0011-class-a-rules-retire` (your rules directory).** It looks for the four former seeds by name: `00-project-binder-pointer.md`, `10-pre-research-library-check.md`, `20-work-project-register.md` and `30-durable-artifact-routing.md`. It compares each one present against a shipped table of every body brain-stem ever seeded, with or without the trailing newline an editor adds. A match is removed, with a line naming the hook that now delivers its guidance. A file that matches nothing is yours: it stays in place with an `ACTION` advisory ending in a `Check:` line:

```
Check: run <path to rules-hygiene.sh> --compare-retired <rule> to print the rule beside what <carrier> delivers.
```

What it will never do: it touches only those four names, and never deletes bytes it cannot prove brain-stem wrote. An absent entry or rules directory is a no-op, and without the recognition table or a hashing tool the whole migration is a no-op rather than a guess.

**`0012-rules-compact-retire` (the librarian's capabilities).** Dropping a file from a release does not remove it from an existing install, so this migration removes `skills/librarian/capabilities/rules-compact.sh`. If the file still matches the bytes your install recorded, it is deleted. If you changed it, or the record is missing, it is renamed aside to `rules-compact.sh.foundation-retired`, so nothing of yours is lost.

What it will never do: it acts on that one path and nothing else, and a home that never had the file is a no-op.

---

## The inbox — every capture is decided when it is made

The inbox is where an idea lands before it becomes a plan. An idea left there undecided is one nobody comes back to, so the decision is now part of the capture.

**A capture must carry a disposition.** `promote-from-inbox.sh --capture <slug>` requires `--disposition`, and only three shapes count as decided:

- **STANDALONE** with `--release-class` (`local-release`, `public-release`, `post-release` or `docs`) and `--size` (`day` or `build`).
- **ABSORB** with `--absorbed-into`, a plan key (optionally followed by `:: T-N`) whose manifest exists.
- **NO-BUILD**, a decided no-for-now, with `--reopen-gate`, the id of a registered re-open gate.

`FIX NOW` is refused, because a fix-now item is fixed rather than captured. A capture must pipe its own body; the empty template, or a decided note with a hollow Idea section, is refused. The old `DEFERRED` disposition is retired; NO-BUILD replaces it.

**Re-open gates.** A NO-BUILD note parks and names a gate id from a closed registry in the plans governance file. Two gates ship: `manual`, which you re-open yourself with `reopen-idea.sh <slug>`, and `r45-gate`, a command gate that is met once the memory-schema check's labelled evidence supports turning its deny on (see below). When a command gate's program exits 0, `/librarian backlog-index` moves the note back into the inbox and stamps which gate re-opened it; a gate that cannot be evaluated is reported and the note stays parked. An overlay can register more gates.

**Near-duplicate scoring.** Before writing, the capture compares its title and Idea section with every open note and shortlists one at a word overlap of 0.33 or more with at least three shared words, or from 0.30 when the two also share a `path:line` cite or the same two opening slug words. A capture with a shortlist is refused unless you fold it in with `--amend <existing>`, or name every shortlisted note with `--distinct-from` and a non-empty `--distinct-scope`. An overlay can retune the thresholds.

**The drain check.** At session close, `inbox-drain-check` blocks the close while a note this session captured is still undecided. It counts only that session's captures, never the whole inbox. The next session start prints `[INBOX UNDECIDED — N]` for those captures and, when the whole inbox holds more undecided notes than the threshold of 10, `[INBOX DRAIN]` with a pointer to `/backlog-triage`. Each banner is silent at zero. A write that leaves an idea note without an in-enum disposition draws an `[inbox-triage]` prompt at once.

**The capture freeze.** When you rule that a project's ideas are to be absorbed into plans, `field-set.sh capture-freeze open <spoke>` records the plans repository's current commit. From then on, `backlog-index.sh --freeze-check` and every backlog index run report each open note of that spoke added after that commit with no target. The freeze blocks nothing; it turns a loose capture into a finding. `capture-freeze lift <spoke>` removes it.

**Targets must resolve.** The session-close handoff check blocks a STANDALONE, ABSORB or NO-BUILD tag in the newest session entry unless the target it names exists on disk. `promote-from-inbox.sh <lead> --absorb <slug>` graduates several notes into one plan, and `backlog-index` settles them when that plan closes.

---

## The plan folder and the research path

**A managed set of twelve names.** A plan folder may hold `manifest.json`, `spec.md`, `tasks.md`, `handoff.md`, `00-ideation-brief.md`, `_research/`, `decisions/`, `_gates/`, `target-state/`, `deliverables/`, `traceability-matrix.md` and `.active-sp`. Anything else at the top of an active plan draws a `plan-unmanaged-entry` finding until you record it with `/librarian plan-asset add <plan-dir> <path> --purpose "<text>"`, one manifest row of path and purpose.

**`_gates/` is a folder convention.** It is one flat folder per plan for the records of whatever review you run: a charge handed to a reviewer, a round record, a verdict, named `NN-gate<k>-<kind>.md`. No brain-stem command writes into it and a new plan does not start with one. It exists so review records never count as research.

**The research inflow guard.** At write time the guard denies two kinds of new file in `_research/`: a gate-named file, with `[GATE RECORD]` and the `_gates/` path to use, and a file whose `NN-` prefix is already taken, with `[RESEARCH PREFIX]` and the next free prefix. An edit is never denied. A shell write bypasses the guard, so the session-close declare step skips such a file and warns, and it is never declared as research.

**The research lifecycle, in one fixed order.** Stage precursor work on a Workshop bench (`/librarian workshop open <key>`); `workshop promote` moves exactly one file into the plan's `_research/` and archives the rest. At session close, `plan-research-declare` records each new file in the manifest. When a later finding replaces an earlier one, `/librarian plan-research-supersede <plan> <old-RA> <new-RA>` marks the old entry superseded, links both ways and banners the old file; nothing is moved or deleted. The binder's research index lists canonical findings first, superseded ones after with a forward link. Library promotion stays propose-then-apply: `library-scrub --census` lists completed plans' unpromoted research, and a promotion queue offers each newly completed plan's research once you set `behavioral.hook_preferences.library_promotion` in your user manifest. A small model then triages it into promote or skip; `prompt` asks you once per close and `auto` answers without asking. Unset reads `off`: no prompt and no model call.

**Pointers, not bodies.** A session launched from a project with an armed plan now receives a `SPEC AUTHORITY` banner (a plan is armed when its folder name sits on one line in `_projects/<spoke>/.active-plan` under your plans folder; no installed brain-stem command writes that pointer, so you write it yourself), the spec's path, the current task, the active decision records and the `plan-context` command, never the spec body. `/librarian plan-context <plan>` prints one slice on demand, and a task's `context_refs` (`<file>#<heading>` or `ADR-NN`) print resolved with `--task`.

**Rulings and decision records.** `/librarian plan-rule` writes a ruling into the newest handoff entry; with `--spec-change` it also mints a decision record and appends one pointer line under the spec's `## Amendment register`. Typing an amendment heading into the spec by hand draws a `[SPEC AMENDMENT]` advisory. An accepted decision record is locked: an edit above its first amendment heading is denied with `[ADR LOCK]`, which names the routes, append a `## Amendment` section or run `/librarian adr-supersede <plan-dir> <old-ADR> <new-ADR>`.

**Handoffs and masters.** `/librarian handoff-entry` stamps the next session entry with its heading, identity header and section skeleton. A launch prompt, the fenced block under a `### Session <N> launch prompt` heading, is word-counted: over 300 words (`LAUNCH_PROMPT_MAX_WORDS`) the write guard adds a `[LAUNCH PROMPT]` advisory and the close-time check warns, never blocks; the target is 200. `/new-plan --graduate <flat-plan> --sub <sub-slug>` turns a flat plan into a master whose first sub-plan is its content, and `/new-plan --rollup <master>` rewrites the master's rollup rows from its sub-plans' manifests instead of by hand. The spec line cap rises from 500 to 1100.

---

## Named commands replace hand-run procedures

Procedures a session used to carry out from a list of instructions are now one command each. A named command checks its input before its first write, refuses with nothing changed when a check fails, writes atomically, and exits with a documented code that tells done from refused from failed. Claude supplies only the judgment, as arguments.

- **`field-set.sh`** sets one field you would otherwise edit by hand: a user-manifest value, a hook off or on, a settings environment entry, a plan's status, paused reason or disposition, and the capture freeze (exit 0 done, 2 refused, 3 refused by a governance gate, 75 lock contention). Messages that used to say "edit the JSON" now print the setter command.
- **`process.sh assemble`** composes a validated governance registration from a proposal and your rulings. `/govern register --kind project` gains `--anchor <dir>`, which registers a launch directory outside your work home, such as a code repository, plus `--retract-sub` and `--emit-moves`.
- **`triage-apply.sh`**, **`reopen-idea.sh`**, **`hygiene-audit.sh`** and **`rehome-stray.sh`** classify a captured note in one write, return a parked note to the inbox, run the backlog hygiene audit, and move a stray plans-root entry into its owning plan. The start-of-session placement banner names `rehome-stray.sh`.
- **`checkpoint-gather.sh`** is the writer behind `/session-checkpoint`: Claude writes the nine session fields, and the command finds the file, reads context pressure, stamps, validates, writes and verifies, then prints one line.
- **`/librarian review`** works the memory review queue as `list`, `show`, `confirm`, `reject`, `defer` and `report`. A deferred item still counts as open.
- **`/librarian skill-referrers <skill>`** lists every file that names a skill, and the write guard's skill-change advisory points at it.
- **`/onboard`** prints the exact `resume-with` command at the pause between its two sections.

Three judgment passes are written up as **single-subagent recipes** in the skills that own them: the `/mem-promote` reshape and conflict pass, the Library promotion fan-out, and the research reads of `/backlog-research`. Each runs in one subagent with a fresh context, never a fan-out, because every extra subagent re-creates the full instruction block. In the first two the subagent writes nothing; the change lands only on your yes.

---

## Guards that fail visibly, and safer defaults

**Checkpoint warnings are banners.** At about 45% context pressure you see, once, "At the next natural break, run /session-checkpoint, then /compact"; at about 48%, once, "Run /session-checkpoint now". Each appears once on entering its band, measured against the window at which Claude Code auto-compacts. The stop-gate in the 48–80% band now accepts a full Continuity Block at any age, and a mechanically extracted checkpoint never counts as rich. After a crash, the next session start extracts a mechanical checkpoint for each crashed session. For a non-Anthropic model the window resolves from your auto-compact setting, else a 64,000-token default, reported as `window_basis`.

**An unreadable governance file is surfaced, never skipped.** A missing source still lets you work. One that exists but cannot be parsed stops visibly: the research inflow guard denies and names it, the session-close research declaration names it on its error output, the placement sweep reports `sweep-failed`, and `plan-rule` exits 2. A pending write the guard cannot check, an unreadable Vault Writers contract or an unreadable overlay registry is likewise denied or exits non-zero.

**Every deny names its fix and leaves a record.** The guard's fail-closed denies now say what to do, and every deny appends one row (time, guard, `DENY`, path, reason) to the local `hook-audit.log`.

**Installed files are protected by default.** An in-place edit of a file the installer laid down is now denied with `[MANAGED-SURFACE DENY]`, naming the route: change your brain-stem clone and ship the change through a release. `MANAGED_SURFACE_OK=1` lets one deliberate temporary edit through and logs it; `MANAGED_SURFACE_PHASE=1-advisory` restores the old advisory-only behaviour.

**Claude Code asks before editing a managed directory.** Install and upgrade append `permissions.ask` rules to your `settings.json`, one per top-level directory the installer manages and one per shipped skill. Each rule is offered once: a rule you remove is never added back. Your own allow, deny, ask and default-mode entries are never removed, rewritten or reordered.

---

## Memory

**`/librarian memory-spill`** moves the coldest non-episodic entries of your `MEMORY.md` index to `MEMORY-archive.md` and leaves one pointer line. It previews by default; `--apply` acts only at the YELLOW band or above, under the consolidation lock, and writes the archive first (exit 75 when the lock is held). The consolidation runner and memory hygiene read the archive, so a spilled entry is never treated as an orphan, and `/mem-promote` skips the archive file, so it is never offered as a new memory.

**Harness-written memory frontmatter is recognised.** Claude Code nests most memory frontmatter under a `metadata:` key. brain-stem now lifts a schema-valid nested type, scope and tags back to the top level, and the consolidation runner reads either shape. The schema check stays advisory and records each would-be denial; `hooks/lib/r45-gate.sh --label` lets you mark those rows, and the gate reports when the evidence supports turning the deny on.

**Visible failures.** An aborted consolidation records `last_result: failed` with the failing check, a missing or unreadable state file is refused before any write, and a failed review-queue write is refused rather than logged as enqueued. Throwaway temp-directory projects no longer get a seeded memory index.

---

## What else is fixed

- **Installer integrity.** A fresh `--apply` from a source tree whose files differ from the shipped manifest refuses with exit 56 before any write. If the delivery check itself cannot run, the apply refuses to write the version stamp. An interrupted upgrade resumes with the plain upgrade command.
- **Pasted cleanup lines are safe.** The closing hints of `install.sh` and `uninstall.sh` print shell-quoted paths. Before, the uninstaller's `rm -rf` prune line printed an unquoted backup path, so a path with a space could delete the wrong directory when pasted.
- **Scheduled jobs.** The session-start launchd hook re-bootstraps a loaded job whose staged plist changed, and reports a failed bootout or bootstrap with its exit code.
- **Lost updates under contention.** Execution-queue writes run under a kernel lock where `lockf` is installed (`--hold` and `--unhold` pause and resume a queued run), and a session registration that cannot take the registry lock is skipped and logged instead of written unlocked.
- **Session close.** The close is idempotent per session, heals a `tasks.md` whose statuses drifted from the manifest, surfaces write failures in its receipt, and runs its weekly checks from the capability registry. `frontmatter-enforce --fix --dry-run` no longer writes.
- **Plan tooling.** The situating card resolves a sub-plan's parent before grouping, rendered tables split only on unescaped pipes, malformed inbox frontmatter is flagged, and adding a sub-plan holds the master's lock.
- **Smaller corrections.** `skill-parity --fix` prints the fix instead of editing an installed skill; four `#log/` subtypes remain (`session-close`, `audit-report`, `backlog-hygiene`, `library-change`); a reference note outside `_library/` missing a required field draws a `[REQUIRED FIELD OUTSIDE SCOPE]` advisory instead of a deny.

---

## Upgrading

- **Upgrade with one command.** From a fresh clone of this release: `install.sh --upgrade` to preview, then `install.sh --upgrade --apply` to perform. Both migrations run automatically, in order, and are safe to re-run.
- **Read the self-check line.** Near the end of the apply the installer reads back the stamp it wrote and prints:

  ```
  install: post-apply self-check: PASS — foundation_version=v1.19.0 confirmed on read-back; migrations: 2 applied this run, high-water log <n> id(s); manifest sha cross-check ok (...)
  ```

  A line beginning `install WARN: post-apply self-check: FINDINGS on stamp read-back` lists what did not match; investigate before relying on the install.
- **Confirm the migrations landed.** Check that both ids are listed:

  ```bash
  jq -r '.migrations_applied[]' "$CLAUDE_HOME/governance/.installed-state.json"
  ```

  The list must include `0011-class-a-rules-retire` and `0012-rules-compact-retire`. If either is missing, run `install.sh --upgrade --apply` once more; the runner selects any migration whose id is not yet listed.
- **If you had edited a former rule seed**, the upgrade's closing `next-steps:` block opens with `ACTION REQUIRED after upgrade:` and names the file. Run the `Check:` command it prints, or `/librarian rules-hygiene --compare-retired <rule>`. Keep the file only for what your edit adds beyond the hook that now delivers it; otherwise delete it.
- **If you had edited any shipped file, including `rules-compact.sh`**, the plain `install.sh --upgrade --apply` stops before it changes anything and exits 52. Two shipped files are the exception: `.gitignore` and `governance/overlay-master.json` hold your own additions, so the upgrade merges them, keeping your entries, and never stops on them. It names each edited file:

  ```
  install FAIL: G2 fired: foreign content (sha256 drift) detected in 1 foundation file(s):
    skills/librarian/capabilities/rules-compact.sh
  install FAIL: Pass --force-install AND type I-UNDERSTAND-OVERWRITE-RISK sentinel to proceed (cp -n preserves your edits; Vault-clobber protection).
  ```

  You have two ways forward. Revert the edit and run `install.sh --upgrade --apply` again, or run `install.sh --upgrade --apply --force-install --i-understand-overwrite-risk`. With the force flags, migration `0012-rules-compact-retire` renames your edited `rules-compact.sh` to `rules-compact.sh.foundation-retired` beside the other librarian capabilities, and every other shipped file you edited is replaced by the shipped version, with your copy kept beside it as `<file>.foundation-local`. Delete either kind of copy when you no longer need it.
- **If you triaged inbox notes as `DEFERRED` in v1.18.0**, those notes still carry `disposition: DEFERRED`, which is no longer a valid disposition, and the upgrade does not rewrite them. Each one draws an `inbox-disposition-out-of-enum` finding every time the backlog index runs, and an `[inbox-triage]` prompt when you edit it. To re-decide a note, open it and set `disposition:` to `NO-BUILD` together with `reopen_gate: manual` (or another id from `hooks/lib/reopen-gate.sh --list`), or to `FIX NOW`, `ABSORB` (with an `absorbed_into:` target) or `STANDALONE`. The triage command `/backlog-triage --item <inbox-slug>` cannot do this for such a note: it only classifies a note whose funnel status is `new`, and it refuses one that carries the retired `DEFERRED` value.
- **If you edit installed files in place**, expect `[MANAGED-SURFACE DENY]`. Make the change in your brain-stem clone, or set `MANAGED_SURFACE_OK=1` for one deliberate temporary edit.
- **Review the new ask rules** in `~/.claude/settings.json`. Remove any you do not want; they are not added back.
