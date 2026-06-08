# Release notes — v1.1.2

> **Audience:** adopters running brain-stem. This page explains, in plain language, what this maintenance release fixes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.1.2 is a maintenance release.** The governance rule *values* are unchanged from v1.1.1 — but this release repairs several ways the system could silently fail to do its job on a real install, plus one bug that could cost you edits, and it tidies internal build shorthand out of the public governance files.

The headline fix: two shipped scripts had lost their *executable bit* — the small flag the operating system uses to decide whether a file is allowed to run — so they silently stopped working after installation. One of them is the **governance write-guard**, the hook that enforces your governance rules on every edit. This release restores both and makes the installer guarantee it can't happen again. Alongside it, several librarian capabilities that quietly exited on a standard install now run, and a reconciliation bug that could overwrite your edits is fixed.

---

## Who this affects

- **Anyone who installed v1.1.1 (and likely earlier).** Two hooks/scripts were delivered without their executable bit:
  - **`pre-write-guard` — the governance write-guard.** Your settings invoke this hook *by path* on every Edit/Write. A non-executable hook can't run, so on affected installs the write-guard **silently failed to fire** — meaning the governance rules it enforces (placement, frontmatter, protected paths) were not being applied at write time. No error was shown.
  - **`placement-validate` — the note-placement checker** that runs at session-close. When it isn't executable, session-close quietly skips it, so misplaced-note violations stopped being reported.
- **Anyone running the librarian on a standard install.** Several librarian capabilities read governance values that ship *inside* the composed governance master rather than as separate files. Because those separate files aren't present on a normal install, the affected capabilities exited early instead of running. This affected backlog indexing, plan archiving, task rendering, and vault-writer reconciliation.
- **Anyone whose vault-writer reconciliation ran.** A configuration-shape bug could cause a reconciliation pass to bypass the step that preserves your manual edits (see *What was broken*, below).
- **Anyone who reads the shipped governance files.** Internal build shorthand in the governance schema/index descriptions is reworded to plain product language — documentation text only, no functional change.

A fresh install made today gets the corrected files directly.

---

## What was broken

brain-stem runs small scripts at defined moments — **hooks** (on edits, at session start/stop) and **librarian capabilities** (at session-close). Several of those failed quietly:

- **Two scripts lost their executable bit.** The operating system only runs a script marked *executable*, and brain-stem's settings invoke hooks **by their path** (not via an interpreter), so a hook that lost its executable bit doesn't run at all — it fails with a "permission denied" error that the surrounding flow treats as a non-blocking hiccup. The **`pre-write-guard`** hook (the single most load-bearing piece of the governance system) and the **`placement-validate`** capability shipped in that state. In both cases the *contents* were always correct; only the runnable flag was missing. The flaw was invisible to the release checks because the file-manifest verified each file's **content**, and nothing asserted a **required** executable bit.

- **Some capabilities expected governance files that a normal install doesn't have.** A few librarian capabilities read their settings from the **plans** and **vault-writers** governance rules. Those rules are *composed into* the single governance master that ships with brain-stem — they are not delivered as separate files. The affected capabilities looked for the separate files, didn't find them, and exited early. So on a standard install, those capabilities weren't doing their work.

- **A reconciliation bug could overwrite your edits.** The vault-writer reconciler decides what to keep when two versions of a record disagree. Its "your edits win" setting was being read from the wrong shape and came back empty, which silently turned the preservation step off — so a reconciliation pass could overwrite manual edits instead of keeping them.

---

## What v1.1.2 changes

- **The executable bit is restored and guaranteed.** Both scripts ship executable again. The installer now re-applies the executable bit to **every** hook and librarian capability after copying them, session-close now reports a shipped-but-non-executable capability as an **error** (instead of silently skipping it), and the pre-tag release gate now asserts the executable bit across the whole managed set — so this class of silent failure cannot recur.

- **The plans/vault-writers capabilities run on a clean install.** Those capabilities now read the effective governance values from the shipped governance master, so they work whether or not the separate rule files happen to be present.

- **Your edits are preserved in reconciliation.** The survivorship setting is read correctly, so the "your edits win" preservation step always applies.

- **Governance is read through one merged view.** Every hook and capability now reads governance through a single merged view — the shipped foundation values, with an optional per-vault overlay layered on top — rather than reading individual rule files directly. For a standard install with no overlay, the effective values are identical to v1.1.1; this makes resolution consistent across the system and is the groundwork for per-vault governance overlays.

- **A post-write verification check is active, and the status line is recoverable.** A verify-after-write check that previously shipped but was registered nowhere now runs after edits, and the installer can restore the status-line command if a local settings file had overridden it.

- **The public governance files read in plain language.** Internal build shorthand in the governance schema/index descriptions is reworded to plain product language. This is documentation text only; every functional governance value is byte-identical to v1.1.1.

---

## What to do

Re-run `install.sh` from the updated source. The upgrade delivers the corrected files (including the restored executable bits) and converges your install. Nothing in your vault or your own settings is changed beyond the managed foundation files.
