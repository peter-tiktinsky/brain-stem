# Release notes — v1.4.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.4.0 is a documentation release.** It does not change anything brain-stem installs or how it behaves — **the foundation is unchanged and there is nothing to migrate.** What it changes is the documentation: the project now ships a complete, navigable documentation site instead of a partial one. If you only ever use brain-stem, you lose nothing by skipping it; if you ever need to understand, configure, extend, or safely remove the system, the answers now exist and are organized.

---

## Why this matters

A tool that installs into the folder your AI assistant reads from, and gives that assistant write access to your notes, has to be *explainable* — you should be able to find out exactly what it does, what it can touch, and how to undo it. Until now the documentation covered the architecture well but left real gaps: there was no security write-up, no single list of the commands the system adds, no glossary, no quick first-five-minutes path, no standalone uninstall page, and no map of *why* the system is built the way it is. This release closes those gaps so that the honest answer to "what is this, and can I trust it?" is one click away.

---

## Who this affects

Everyone — but there is nothing you are required to do.

- **People evaluating brain-stem** get a front-door README, a one-page "Why brain-stem," a plain-language concepts tour, and a five-minute quickstart.
- **People running it** get a command reference, an FAQ, a glossary, a standalone uninstall guide, and a version-migrations guide.
- **People extending or auditing it** get a "Design decisions" overview that maps every load-bearing choice to its evidence, plus a security write-up.

Because the installed foundation does not change, **you do not need to upgrade for this release.** Upgrading is optional and only refreshes the project files in your local clone (the README and the new `SECURITY.md`); the live documentation is always current at the site below.

---

## What changed

All changes are documentation; none touch the install.

- **A new `SECURITY.md`** — the scope of trust (brain-stem runs locally and makes no automatic network calls; the only network activity is user-invoked, to your own destinations), the install/overwrite surface, the vault-write blast radius, and how to report a vulnerability privately.
- **A new Reference section** — a command reference for every command brain-stem adds, a global glossary, and an FAQ.
- **New getting-started pages** — a five-minute quickstart, a version-migrations guide describing what each release moves for you automatically, a standalone uninstall how-to, and an optional claude-mem page.
- **A "Why brain-stem" keystone** and a "Design decisions" overview that make the case for the system and tie each choice to durable, independently checkable evidence.
- **Context-library documentation** — a context-and-memory umbrella and a context-library deep-dive for the three-surface model that shipped in v1.2.0.
- **Every architecture page** now opens with a "what the bare platform gives you → where it falls short → what brain-stem adds" frame and closes with its own evidence-and-alternatives section.
- **The site navigation is now explicit and ordered**, and the documentation build is pinned to a known-good toolchain version.

---

## What to do

Nothing is required. To read the new documentation, visit the site:

> **<https://peter-tiktinsky.github.io/brain-stem-docs/>**

If you keep a local clone and want the refreshed project files (the new README and `SECURITY.md`), pull the latest source — there is no install step, because nothing about the install changed:

```bash
cd brain-stem
git pull
```

That is the whole release: better documentation, no change to what runs on your machine.
