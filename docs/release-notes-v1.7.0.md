# Release notes — v1.7.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.7.0 removes the built-in `System Governance/` folder from the vault that setup creates.** That folder used to be seeded into your vault as a set of in-vault narrative pages explaining each governance rule. Those explanations now live in the documentation site instead, so the foundation no longer plants a copy inside your vault. Nothing you have written is touched.

---

## Why this matters

When brain-stem set up your vault, it seeded a `System Governance/` folder: a handful of read-only narrative pages — one per governance pillar (naming, tagging, frontmatter, mandatory files, file-type contracts, doc-dependencies) plus an index — describing how each rule works. They were reference reading, not something the system read at runtime.

Two things made that folder worth removing. First, the same content is published, in full, on the documentation site (under the *governance engine* and *vault governance* pages) — so the in-vault copy was a second, drift-prone duplicate of the canonical narrative. Second, seeding read-only explanatory pages into *your* vault blurs the line between what the foundation owns and what you own: the universal base should plant working surfaces, not documentation.

**v1.7.0 stops seeding the folder.** The governance narrative is unchanged and fully available — it simply lives in one canonical place (the docs) rather than being copied into every vault.

---

## What changed

### Removed

- **The seeded in-vault `System Governance/` folder.** A fresh setup no longer creates it. The per-pillar governance narrative it held is published in full in the documentation site — the *governance engine* and *vault governance* pages carry the complete write-up, so no explanation is lost.

### Changed

- **The "this is a brain-stem vault" marker moved.** brain-stem recognizes a vault it built by looking for a small marker file. That marker used to be the `System Governance/` index page; it is now `Vault Writers/_index.md`, a page that setup already creates and that is not going anywhere. This is invisible in normal use — it only matters so that re-running setup on a vault brain-stem already built is still recognized and never mistaken for someone else's folder.

---

## Who this affects

- **Fresh adopters: nothing to notice.** Set up as usual; the `System Governance/` folder simply is not created. Re-running setup on the vault it just built is still recognized correctly (via the relocated marker) — there is no change to how setup behaves.
- **Upgrading adopters: nothing is touched.** See *Upgrading* below for the one small detail.
- **Anyone reading the governance narrative:** read it on the documentation site — it is complete and current there.

> **<https://peter-tiktinsky.github.io/brain-stem-docs/>**

---

## Upgrading

Upgrade the way you always do (`bash install.sh --apply` from your local clone, or your usual upgrade flow).

**Your already-seeded `System Governance/` folder is never touched.** Upgrading does not re-run vault setup, so a `System Governance/` folder that an earlier version seeded into your vault stays exactly where it is. It quietly becomes ordinary, user-owned content: brain-stem no longer treats it as a foundation surface. **Keep it, edit it, or delete it — entirely your choice.** Nothing in the system depends on it either way.

**One small leftover.** brain-stem keeps a copy of the seed files it ships inside your install directory (`~/.claude/vault-init/`). The upgrade delivers and updates the files brain-stem manages, but it does not reach in and *delete* a seed file that an earlier version shipped and this version no longer does. So after upgrading you may still find an inert `vault-init/System Governance/` set under your install directory. **Nothing reads it at runtime** — it is harmless residue, not a working surface. You can leave it or delete it manually; either is fine.

**Editing a leftover governance page.** If you keep one of the old `System Governance - *.md` pages and edit it, you may see a one-line note. There are two cases, both harmless:

- If the page still declares the old document type (`type: system-governance-spoke` in its frontmatter), the governance check recognizes that type as **retired** and tells you so directly — it is a clear retirement message ("this type is retired; the file is now plain user content; pick an active type that fits, or leave it untracked"), **not** an "unknown type" error or a hard failure. The page is yours now; the rule it once mirrored lives in the docs.
- If you keep the whole `System Governance/` folder, a write into it may surface a gentle, skippable suggestion to register the folder (the same prompt you would get for any folder brain-stem does not recognize). It never blocks the write — your content is yours.

In short: your content is preserved, nothing is pruned out from under you, and the only prompts you might see are advisory.

---

## In one sentence

brain-stem stops seeding an in-vault `System Governance/` folder — its governance narrative now lives solely in the documentation — while every already-seeded folder is left untouched as your own content and the only leftover is inert, harmless install-directory residue.
