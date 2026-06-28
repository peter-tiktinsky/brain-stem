# Release notes — v1.6.1

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed.

**v1.6.1 is a documentation release.** It does not change anything brain-stem installs or how it behaves — **the foundation is unchanged and there is nothing to migrate.** It brings the documentation back into step with the system as it actually ships after v1.5.0 and v1.6.0: a command that existed but was undocumented is now listed, the vault tour now mentions every shortcut that setup creates, and a few stale cross-links and one leftover reference are corrected. If you only ever use brain-stem, you lose nothing by skipping it; the live documentation site is always current regardless.

---

## Why this matters

Two recent releases added capability faster than the documentation caught up. v1.5.0 added a fourth context surface — `work/`, for deliverable-centric work — and a `/deliver-export` command to turn a finished deliverable into a `.docx` or PDF. The reference documentation never picked either up: the command list omitted `/deliver-export` entirely, and the vault tour still described "four" convenience shortcuts when setup now creates five. This release closes that gap so the documentation describes the system you actually have.

---

## Who this affects

Everyone who reads the documentation — but there is nothing you are required to do.

- **People evaluating brain-stem** now see the complete command set (including `/deliver-export`) and an accurate description of the vault that setup builds.
- **People running it** get "what changed" links that point at the current release rather than an old one.

Because the installed foundation does not change, **you do not need to upgrade for this release.**

---

## What changed

All changes are documentation; none touch the install.

- **The command reference now lists `/deliver-export`** — the command, shipped in v1.5.0, that exports a finished `Work/` deliverable to a shareable `.docx` or PDF. It was working but undocumented; the reference now covers it, bringing the count of commands you run directly to ten.
- **The vault tour now describes all five setup shortcuts.** The architecture and onboarding pages said setup wires "four" convenience links and listed only `Plans/`, `Skills/`, `Wiki/`, and `Projects/`. Setup also creates a `Work/` shortcut — the deliverable surface added in v1.5.0 — so the docs now say five and list it.
- **"What changed" links now point at the current release.** A few cross-links in the getting-started and migrations pages still pointed at older release notes as if they were the latest; they now point at the current release.
- **A leftover reference is cleaned up.** The command reference described an "ingestion script" tied to a capability that was removed; the wording now reflects only what ships.

---

## What to do

Nothing is required. To read the updated documentation, visit the site:

> **<https://peter-tiktinsky.github.io/brain-stem-docs/>**

If you keep a local clone and want the refreshed files, pull the latest source — there is no install step, because nothing about the install changed:

```bash
cd brain-stem
git pull
```

That is the whole release: documentation that matches the system, no change to what runs on your machine.
