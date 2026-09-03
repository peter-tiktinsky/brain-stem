# Release notes — v1.18.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.18.0 is a minor release that ships two automatic upgrade-time migrations.** A migration is a self-contained, idempotent step that runs during a normal upgrade and converges your existing installation to the new state; you do not run it by hand, and running it twice changes nothing the second time. One of this release's migrations touches your plans corpus and one touches your rules directory, so this page says exactly what each does and what it will never do. The headline change is a **smaller always-on context budget**: the instruction text brain-stem loads into every session start is cut substantially, a template leak that padded every fresh memory index is closed, and a shipped monitor now measures every loaded instruction surface per session so the cost is a number rather than a guess. Alongside: plan arming is scoped to the project that armed it, task statuses converge on one declared vocabulary, and the dangling-link check stops reporting two classes of legitimate link as broken.

---

## The headline — a smaller always-on context budget, and a monitor for it

Claude Code loads a set of instruction files at the start of every session: your `CLAUDE.md`, every markdown file in your rules directory, and your memory index. Everything loaded there is paid for on every session start and on every subagent spawn, whether or not the session needs it. brain-stem seeds several of those files, and this release makes the seeded set smaller and measurable.

**The four seeded rule entries are rewritten to about a third of their size.** The installer writes four always-on rule entries into your rules directory (the project-binder pointer, the pre-research library check, the work-project registration on-ramp and the durable-artifact routing convention). Their guidance is unchanged; their wording is compressed from five entries totalling about 6.8 KB to four totalling about 2.4 KB. A fifth entry, the bounded-spoke rule, is retired outright, because the session-start hook that warns when a session is launched from your home directory already delivers the same guidance at exactly the moment it applies.

**The rules README stops loading as a rule.** The harness loads every markdown file in the rules directory at launch, and the README the installer seeded there was authoring documentation, not a runtime instruction. It is no longer seeded there. Its canonical copy still ships, installed alongside the other templates, and the write-time advisory that guides rules authoring points at it.

**Fresh memory indexes no longer inherit template scaffolding.** The memory-index template documented itself in comment blocks, assuming the harness would strip them. It strips them only in a narrow shape, so every freshly seeded index carried 2,529 bytes over 50 lines of scaffolding where 55 bytes over 7 lines were intended. Both seams are closed. Existing indexes are not rewritten — the leak was seeding-time only — and the template now carries a short visible note naming the three memory types and where the schema lives.

**A shipped monitor measures the budget.** The hook on the instructions-loaded event now records the size of every instruction file the harness reports loading, the session-end hook counts any hook output that overran the harness's 10,000-character cap and was spilled to disk instead of delivered, and a new librarian capability, `context-budget-index`, renders those measurements against declared per-surface thresholds with warning and red bands. The thresholds live in the shipped governance bundle, so an overlay can tune them.

**Hook-backed rules can be compacted.** Some rules exist only as a human-readable restatement of something a deterministic hook already enforces; the model does not need the prose, only the pointer. A new librarian capability, `rules-compact`, compacts such a rule to a short stub that names the enforcing hook, recording the link in a new `enforced_by` field of the rules schema. It refuses any rule that lacks the keep-and-why markers the compaction needs, so a rule is never emptied by accident. The memory-globalize capability gains a `--target` flag so a promotion can be aimed at a chosen rules directory.

**Two smaller trims** in the same thread: seven shipped skill descriptions are trimmed by about 400 bytes in total (the harness renders the skill roster into every session), and the decision-quality guard stops citing CLAUDE.md section headings that no install path produces.

---

## The two migrations — what each does, and what it will never do

**`0009-task-status-vocabulary` (your plans corpus).** Every plan manifest carries a task ledger, and each task carries a status. The declared vocabulary is five values — `not-started`, `in-progress`, `blocked`, `done`, `cut` — with `done` and `cut` as the terminal pair. Corpora authored before that declaration carry eight legacy spellings, and each reader had its own idea of which were terminal, so the same task could read as settled to one reader and open to another. This migration maps the eight legacy spellings forward (`complete`, `completed` and `closed` become `done`; `pending` and `planned` become `not-started`; `needs-revision` becomes `blocked`; `deferred` and `retired` become `cut`).

What it will never do: it touches the task axis only — a plan's own status field and the sub-plan status mirrors are a different vocabulary, owned by an earlier migration, and are left byte-identical. Only the eight exact spellings are mapped; every other value, including a canonical one, an absent one, or a free-form settled disposition, is left byte-unchanged and the migration keeps going rather than aborting. This corpus rewrite lands outside the installer's rollback envelope, but it is recoverable: before any manifest is changed its original bytes are copied once to a `.pre-0009` sidecar beside it, and because the mapping is convergent, simply re-running the upgrade re-converges the corpus. The sidecars are recovery artifacts, safe to delete once you have verified the upgrade.

**`0010-class-a-rules-refresh` (your rules directory).** The installer seeds rule entries with a preserve-on-exist rule — it never overwrites a rules file that is already there — so a content change never reaches an install that is already seeded, and a seed the installer stops writing is never removed. This migration is the only delivery path for both. It has three arms, and each acts only when it recognises the file as bytes this project itself wrote, by comparing against a shipped table of every body ever seeded: it replaces a seeded entry with the current shortened body when the file still matches an older seed; it retires the rules README when it matches a shipped seed, and otherwise preserves your content under `rules/README.md.foundation-retired`, a name the harness does not load; and it retires the bounded-spoke rule when it matches.

What it will never do: it touches only the rules directory, and it never destroys adopter-edited bytes — a file that matches no seed is left exactly as it is, with an advisory naming it. A missing entry is a no-op, because the seeder runs earlier in the same upgrade and has already written the current body. If the recognition table or a hashing tool is unavailable, the whole migration degrades to a no-op rather than guessing.

---

## Plan arming is scoped to the project that armed it

brain-stem lets you arm a plan for build: the armed plan's spec is injected into sessions as the authority a brief must defer to. Until now the pointer that named the armed plan was one corpus-wide file, so only one plan could be armed on a machine, and every session on the machine — whatever project it was launched from — received that plan's spec head, the largest hook payload brain-stem ships.

The pointer now lives inside each project's own binder directory, at `_projects/<spoke>/.active-plan`, and every reader resolves it through one shared library. Two projects arm at the same time without contention; a session receives the spec of the plan armed in the project it was launched from, and nothing else; a session in a project with nothing armed receives nothing. The old corpus-wide pointer is still honoured as a read-only fallback so nothing breaks on the way over, but nothing writes it any more.

---

## What else is fixed

**Dangling-link findings are trustworthy again.** The write-time check that reports broken wikilinks flagged two whole classes of legitimate link: a `[[name.ext]]` link whose target is not a markdown file, and a `[[Surface/...]]` link whose target is reached through a symlink at the vault root. Both resolve now, so a dangling-link finding means what it says.

**One terminal split for tasks.** The reader that builds a project's situating card decides whether a task is settled by the declared terminal pair, `done` and `cut`, instead of a private broader set — in lockstep with the task-status migration, so a converged corpus and its readers agree.

**The session chronicle pointer lands on template-seeded indexes.** The session-end hook that keeps a pointer to the recent-sessions chronicle in your memory index chose its branch with a substring test and did the replacement with an exact-line test. On an index seeded from the template those two disagreed, the file was rewritten unchanged, and the pointer never landed. One shared whole-line predicate now drives both, and the chronicle indexer locates its sentinels by anchored line so it can only ever touch a live block.

**Rotated chronicle archives stop polluting the memory index.** The memory-consolidation check that indexes orphaned memory files treated every rotated chronicle archive as a new entry, appending a dead line with an empty hook per rotation, forever. The archives are now exempt.

**The memory-index cap is stated in the unit the harness measures.** The harness loads the first 200 lines or 25,000 UTF-16 code units of the stripped memory index, not the first 25,600 raw bytes, and it appends a visible warning when it cuts. The governance mandate, the write-time guard and the template now say exactly that, and the warning band no longer sits inside the window where the index was already being cut.

---

## Smaller changes worth knowing

- **claude-mem guidance.** If you run the optional claude-mem plugin, the onboarder's external-setup step, the onboarder skill and the README now tell you how to turn off the context index it injects at session start, and why shrinking it to sit just under the hook-output cap is worse than either extreme. brain-stem ships guidance only — it never writes to the plugin's configuration.

---

## What to do

- **Upgrade with the one-command lane.** From a fresh clone of this release: `install.sh --upgrade` to preview, then `install.sh --upgrade --apply` to perform. Both migrations run automatically, in order, and are safe to re-run; a second pass changes nothing.
- **Confirm the migrations landed.** After the apply, check that `governance/.installed-state.json` under your Claude home lists both `0009-task-status-vocabulary` and `0010-class-a-rules-refresh` in `migrations_applied`:

  ```bash
  jq -r '.migrations_applied[]' "$CLAUDE_HOME/governance/.installed-state.json"
  ```

  If either is missing, run `install.sh --upgrade --apply` once more — the runner selects any migration whose id is not yet in that list and heals the install; no manual step is needed.
- **If you scripted against the legacy task statuses** (`complete`, `completed`, `closed`, `pending`, `planned`, `needs-revision`, `deferred`, `retired`), point those scripts at the five declared values — the migration has already converged your corpus.
- **If you had edited a seeded rule entry**, the rules-refresh migration leaves your file alone and names it in an advisory; compare it against the shortened body at your convenience.
