# Release notes — v1.14.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.14.0 is a minor release with no migrations.** Upgrading is a file sync — nothing runs against your plan corpus or your configuration, and nothing needs doing by hand. The widest-reaching change is invisible day to day but touches every session: **the short background jobs brain-stem detaches when a session starts and ends no longer inherit whatever environment the session happened to have**, so such a job can no longer end up operating on a different install than the one that spawned it. Alongside it: the governance overlay stops accepting a customization shape it could never honor, every shipped file-type contract now carries an explicit disposition — registered, aliased, or path-governed — instead of nine of them sitting unaccounted for, several librarian checks now do what they describe, and the parts of your install that you own are documented as yours. **Upgrade normally with `install.sh --apply`.**

---

## The headline — detached session-boundary work stays inside its own install

When a session starts and ends, brain-stem launches a few short *detached* background jobs — work that continues after the thing that started it has moved on, so the session is not held up (refreshing indexes, consolidating memory, recording that the session ended).

A detached job inherits the environment of whatever spawned it. brain-stem's path resolver supplies a default location for the Claude home directory when nothing else has set one, and it does that by minting the value in the parent process and handing it down to every child. Nothing pinned it. So the install a background job worked on was decided by ambient state rather than by the job's own caller.

For an adopter running a single install in the default location, parent and child agree and nothing is wrong. The problem appears whenever a session runs against a **different** Claude home — a relocated install, a temporary one, a test or evaluation copy. In that situation a detached job could:

- run the **live** install's capability scripts rather than the ones belonging to its own home, because the capability directory was resolved from the inherited value rather than from the script's own location;
- read the **live** install's configuration file, and with it every path that file supplies — including the vault location, which deliberately has no fallback default;
- and in one case **write**: the memory-consolidation job re-resolved its own memory directory child-side and created that directory.

That last one is why this is a fix rather than a tidy-up: a read resolving to the wrong place is a wrong answer, but a write resolving to the wrong place leaves something behind.

v1.14.0 pins the environment explicitly at every detached spawn point before the hand-off, so a background job always operates on the install that spawned it. **Three hooks that run at every session start and end are affected**, which is the widest blast radius in this release — if you evaluate one thing before upgrading, evaluate that.

A related fix ships alongside: background capability jobs inherited an open input stream that never reached end-of-file, so a capability that read from input could wait indefinitely instead of finishing. Those jobs no longer block on it.

---

## What else is fixed

**An overlay that sets a file type to null no longer corrupts that type.** The *overlay* is how you customize governance rules: your file is merged over the shipped one, so you can add rules or replace shipped values without editing the shipped copy. Two things were true at once — the merge underneath cannot delete a key, and the guard that works out which file types are accepted read them off the merged result without subtracting anything. Setting a file type to `null` therefore produced a type that was still accepted but carried no contract at all: worse than not having tried. That shape is now rejected with a finding that names it.

**Every shipped file-type contract is now explicitly accounted for.** A *file-type contract* declares which fields a given kind of file must carry. The foundation ships thirteen of them, but its type registry names only six types — four more contracts were wired through those registered types under different names, and the remaining nine had no recorded relationship to enforcement at all. Each contract now carries an explicit disposition in the governance rules: registered to a type, an alias of a registered type, or governed by the file's path with the contract text serving as documentation. Be clear about what this is: **an accounting change, not new enforcement.** No previously-inert check starts firing. What closes is the gap where a contract could sit unregistered with nothing even recording whether it was supposed to enforce — that question now has a written answer for all thirteen.

**Several librarian checks now match their own descriptions.** The librarian is the maintenance skill that audits and regenerates your indexes and validates your plan corpus. A sweep of its own contract surfaces found places where its description had drifted from its behavior while every check still reported green. Fixed and added here: the check that verifies session handoffs record a disposition for every follow-up no longer raises false positives on plan names and inline code; a standing parity arm now *measures* that every capability which walks your vault actually reaches through the symbolic links the vault view is composed of — a walk that silently stops at a link boundary is now a reported drift instead of an invisible coverage gap; and the tag vocabulary the generators emit is asserted against the registry that declares it, so the two cannot drift apart unnoticed. Two behavior changes ride along and are worth knowing: the generators' emitted project tag loses a trailing `s` — it is now `#project/<name>`, where earlier versions emitted the plural form of the same prefix (files generated by earlier versions keep the plural until they are next regenerated — nothing rewrites them), and wikilink targets that live in the memory corpus — your rules directory and per-project memory — are no longer reported as broken links, which removes a persistent noise floor from that finding class.

---

## Work in this release you will not see listed

This release also carries a body of work on brain-stem's own internal test infrastructure —
making the verification suite deterministic when parts of it run concurrently, and isolating each
run's temporary state so runs cannot interfere with one another.

None of it ships. It lives entirely in the development repository's test tree, which is excluded
from the published surface, so there is no change for you to evaluate, adopt, or verify. It is
mentioned here only because it accounts for a substantial share of the change volume behind this
version, and a changelog that silently omitted it would make the release look smaller than it was.

---

## What changes for the parts of your install you own

Two locations inside your install are written by brain-stem's own shipped capabilities at runtime: your **rules directory** and your **per-project memory**. Because shipped features write them, neither is write-protected — that was always deliberate, and this release writes it down instead of leaving it implied.

The practical guarantee: **the rules brain-stem seeds are written only when absent.** A rule you author, or one you have edited, is never overwritten by a later `install.sh --apply`.

The honest trade-off, stated so it is not a surprise: because seeding never clobbers, an **updated** version of a seeded rule reaches only new installs. If a future release improves the wording of a rule that is already present in your install, your install keeps the copy it has. This is an accepted, documented trade-off, not an oversight — and if a future change to a seeded rule genuinely must reach existing installs, it will ship as a migration.

---

## What changes at upgrade

**Nothing new runs when upgrading from the previous release.** This release ships no new migrations, so an upgrade from the immediately prior version synchronizes files and stops there — your plan corpus, your configuration, your rules and your memory are untouched. If you are upgrading across several versions at once, migrations from the releases you skipped that have not yet applied to your install still run, as they always do.

---

## Who this affects

- **Everyone**, for the session-boundary fix: three hooks that run at every session start and end changed. Nothing about it is visible in normal use.
- **Anyone who runs brain-stem against a non-default Claude home** — a relocated, temporary, test or evaluation install. This is the group the headline fix actually protects; before it, a detached background job in such a session could resolve to a different install.
- **Anyone who customizes governance through an overlay**, for the null-rejection fix and for the contract-disposition table. One caution the table makes visible: if you had been assuming a shipped contract was enforced for one of the previously-unaccounted types, the disposition now tells you plainly whether it is — for most of them the answer is that the contract is documentation governed by path, and **no check runs**. Nothing new fires and no new findings will appear from this change; what you gain is a truthful record to check your assumptions against.
- **Anyone who authors their own rules**, for the written guarantee that your edits survive upgrades.

---

## What to do

1. Upgrade normally: `install.sh --apply`.
2. Nothing else is required — there are no migrations to verify in this release.
3. If you customize governance through an overlay and had assumed a contract was enforced for one of the previously-unaccounted file types, read its row in the new disposition table — it now states plainly whether any check runs for that type. No new checks fire in this release, so no new findings will appear; the table is where to verify what is and is not enforced.
