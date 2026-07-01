# Release notes — v1.9.1

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.9.1 is a maintenance release — four defect and hardening fixes, all internal to how brain-stem runs.** Nothing about how you author your vault, projects, or plans changes, and there is nothing to migrate. The fixes make three pieces of brain-stem's own bookkeeping honest again, and harden how scheduled jobs are generated on macOS.

---

## What's fixed

- **The context-pressure reading no longer cries wolf on large-context models.** During a session, brain-stem shows a "context pressure" reading — how full the conversation is getting — and prompts you to checkpoint when it climbs. That reading was dividing by a fixed 200,000-token budget, but today's models hold 1,000,000 tokens. The result was a reading that pinned near 100% — and a checkpoint prompt that fired — when the session was actually only moderately full. It now uses the model's real context window (1,000,000 for the current Opus / Sonnet / Fable models; 200,000 for Haiku; a safe default for anything it doesn't recognize), so the reading and the prompt reflect real pressure. If you set the context window explicitly with `CLAUDE_CONTEXT_WINDOW`, that still takes precedence.

- **The "active peer sessions" count no longer counts sessions that have ended.** When you run more than one session at once, brain-stem notices and tells you how many other sessions are active, and warns when two sessions are editing the same file. That tally was counting *every* session it had ever recorded — including ones whose process had already exited or was never fully recorded — so the number was inflated (you might see "14 active peer sessions" with only a handful actually running). brain-stem now checks each recorded session against its real operating-system process: ended and unrecorded entries are dropped from the count and cleaned out of the registry, so the number reflects sessions that are genuinely running.

- **Plans numbered 100 and above work again.** brain-stem numbers your plans with a prefix (`01-…`, `02-…`, and so on). The rule that validates those names accepted only a two-digit number, so once you reached plan 100, creating or graduating a new plan was rejected. The rule — and every place that re-checks it — now accepts numbers of two or more digits. Most people will not hit this until they have run more than 99 plans; if you have, plan creation and graduation work normally again.

## What's hardened

- **Scheduled jobs fail loudly instead of dying silently on a privacy-protected log path.** brain-stem can generate scheduled background jobs (via macOS's `launchd`). On current macOS, if such a job is told to write its log into a privacy-protected folder — your Desktop, Documents, Downloads, or iCloud Drive — the operating system refuses to start it at all, and it dies before running with no error you would ever see. The job generator now refuses to produce a job pointed at one of those folders and fails immediately, at generation time, with a clear message; a release-time check enforces the same rule on the templates brain-stem ships. A standard install already logs to a safe location, so nothing changes for you — this is a guard that turns a silent failure into an obvious one.

---

## Who this affects

- **Everyone** gets the corrected context-pressure reading and the corrected active-session count — both are part of brain-stem's normal in-session behavior, so the fixes apply automatically once you upgrade.
- **People who run many plans** get plan numbers past 99 working again.
- **People who use brain-stem to generate scheduled jobs** get a loud failure instead of a silent one if a job's log path is ever set to a privacy-protected folder.

---

## Upgrading

Upgrade the way you always do (`bash install.sh --apply` from your local clone, or your usual upgrade flow).

**Everything in v1.9.1 is a fix or a guard.** Nothing changes how your vault, projects, or plans behave, and there is nothing to migrate. The upgrade does not touch your existing notes, plans, projects, or wiki.

---

## In one sentence

brain-stem v1.9.1 fixes three pieces of its own bookkeeping — the context-pressure reading, the active-session count, and plan numbering past 99 — and hardens how scheduled jobs are generated on macOS, with nothing to migrate.
