# Release notes — v1.13.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.13.0 is a governance-integrity release: it makes the machinery that maintains your plan corpus actually do its job, simplifies the plan lifecycle to statuses that mean something, and cleans up after its own retirements — in the shipped product and in your existing install.** It is a large hardening train, and it ships **three automatic upgrade-time migrations**: self-contained, idempotent steps that run during a normal upgrade and converge your existing installation to the new state. **You do not need to run anything by hand** — but because these migrations touch files in your plans corpus and your install, this page explains exactly what they do and what they will never do.

---

## The headline changes

### 1. Session close now genuinely maintains the governance substrate

brain-stem's "governance substrate" is the set of generated records that keep a plan corpus coherent: the backlog view, the plan indexes, the maintenance sweeps that catch drift. In prior versions, responsibility for writing these was spread across multiple writers, some of which could silently skip their work while still recording success. This release rewires that: **the session-close pipeline is now the single writer**, orchestrating the backlog regeneration, index refreshes, and due maintenance sweeps on a real cadence each time a session ends — with crash recovery, so a close that is interrupted mid-way is picked up and finished rather than abandoned. The practical effect: the generated views you rely on stop drifting from reality, because the moment that produces them is wired, triggered, and accountable.

### 2. The plan lifecycle simplifies to six statuses

A plan now moves through **`researching` → `planned` → `in-progress` (with `paused` available) → `completed`**, with **`superseded`** for a plan replaced by another. Three statuses are retired because they asserted guarantees the system never actually delivered: a separate "verified" state (nothing distinct verified it), and "closed"/"archived" as status values (they duplicated "done" while implying an extra ceremony). "Done" is now one state — `completed` — and completing a plan stamps a completion timestamp on its manifest so the record answers when it finished. Archival still exists, but as a **display-only view filter** in the rendered indexes: you can tuck old plans out of sight without a status change.

**The migration (automatic):** your existing plans were authored under the old vocabulary, and the new, tightened schema would reject the retired tokens. The upgrade therefore runs a one-time convergence over your plans corpus: each manifest whose own status is `verified`, `closed`, or `archived` is mapped to `completed`, and the same mapping is applied inside each master plan's sub-plan status mirrors. The rewrite is **in-place and content-preserving** everywhere else — element order, timestamps, and every other field are preserved (a manifest that changes is re-serialized in the scaffolder's canonical formatting), and the migration writes **no new timestamps** (historical graduation times stay historical). It is idempotent: run twice, the second pass changes nothing. **This corpus rewrite lands outside the installer's rollback envelope** — your plans corpus is not part of the install snapshot — **but it is recoverable:** each manifest that changes is first snapshotted to a `.pre-0006` pre-image file beside it, and because the mapping is convergent, re-running the upgrade re-converges the corpus.

### 3. Retired surfaces are removed — from the ship and from your install

Deleting a file from the shipped product does not delete it from an existing installation: upgrades visit the files the new version lists, so a file the new version *stopped* listing would linger on disk forever — inert at best, misleading at worst. This release removes every retired or inert surface from the shipped foundation, and ships a migration that removes them from existing installs **by name** (never by a blanket diff, which could delete files that were deliberately handed over to you):

- Each retired foundation file is checked against the shipped baseline record first. **Unmodified copy → removed. Modified copy → renamed aside with a `.foundation-retired` suffix, never deleted** — if you customized a file that is now retired, your bytes survive under the renamed path.
- Retired runtime outputs (state files the retired services produced) are removed if present — files only (plus a guarded `rmdir` of the single `state/` directory once it is emptied), never other directories, and never the audit/forensics logs.
- The one retired hook entry is un-wired from your live settings, so it stops erroring on every session stop now that its target is gone.

### 4. The idea-inbox becomes a ledger

The inbox — where ideas are captured before they become plans — previously worked as a capture-and-graduate pipe: an item either graduated into a plan or sat there, and nothing could say authoritatively which captured ideas were still owed an outcome. Now every item carries its owning project and its disposition target as machine-readable fields from the moment of capture, dispositions must point at targets that actually resolve, and a settled ledger plus an inbox index close the loop. The backlog view can now answer: *which captured ideas are fully settled, and which are still open?*

---

## Also in this release

- **Governance reads see your customizations.** brain-stem layers your adopter overlay (your local rule customizations) over the shipped foundation. Readers that previously resolved only the foundation copy now resolve the union through the shared merger. (A few low-level readers — the plans-root namespace guard and two derived-index renderers — still read the foundation copy directly.)
- **Deterministic librarian capabilities run without an interactivity guard.** The read-only capabilities (index renders, validations, audits) no longer refuse to run outside an interactive session — automation can invoke them freely. The two capabilities that actually *apply* changes now refuse to run unattended unless an interactive-session signal is present, so an accidental bare or automated invocation of a mutating capability is prevented.
- **Relocated Claude homes work.** Shipped hooks no longer hard-code the default home directory; installs under a custom Claude home resolve their own paths.
- **Failures surface as failures.** Error-exit hardening across shipped shell surfaces means a failing step stops the pipeline visibly instead of dying silently. The upgrade-time migrations refuse with a remediation message when python3 is missing, and the installer warns at install time when the optional `pyyaml` module is unavailable. (Runtime capabilities keep their as-designed fail-open posture: when python3 is absent they skip their optional work silently rather than block a session.)
- **The traceability-matrix pipeline ships intact.** Through v1.12.x, the ship transform stripped the `traceability-matrix` filename out of the shipped matrix code, so the pipeline read and wrote a hidden dotfile and the advertised auto-render never fired for an adopter. The filename is preserved end-to-end now; the matrix renders to `traceability-matrix.md` as documented.
- **Your overlay's dimension-prefix lists are normalized.** The dimension-prefixes migration — the first of the three to run — converges the `dimension_prefixes` populations in your overlay-master to the canonical array-of-slugs shape the union readers require; an already-array leaf is left byte-untouched, and the step is idempotent.
- **Docs tell the truth about enforcement.** A sweep across the shipped documentation removed overclaims — most notably, the read-only verification agents no longer advertise a functional-correctness pass they structurally cannot execute, and each contract field's description names its real consumer.
- **Precision fixes across the substrate:** lifecycle-cap enforcement, change-detection reporting, drift-finding placement, registry meta-gate validation, the vault-writers parser, the maintenance cadence wiring, the memory-rules tier, and a clean home-spoke render in the plan index.

---

## Who this affects

- **Every adopter** gets the substrate-integrity and truth-in-docs fixes automatically; the generated views (backlog, indexes) become reliable at session close.
- **Adopters with an existing plans corpus** are affected by the status-vocabulary migration: any plan carrying a retired status is converged to `completed`. If you scripted against the old status values, update those scripts to the six-state vocabulary.
- **Adopters who customized a now-retired foundation file** will find their copy preserved under a `.foundation-retired` name rather than deleted. If you never modified those files, they are simply removed.
- **Automation authors** benefit from the librarian guard partition: read-only capabilities can now be scheduled without interactivity workarounds.

## What to do

- **Upgrade normally** (`install.sh --apply`). The three migrations run automatically, in order, and are safe to re-run; a second pass changes nothing.
- **After upgrading,** if you had scripts matching the retired statuses (`verified`, `closed`, `archived`), point them at `completed` — the migration has already converged your corpus.
- **If you customized a retired file,** look for `*.foundation-retired` alongside its old path if you want to salvage anything from it; otherwise ignore it or delete it at leisure.
- **Nothing else requires action.** No file format you author by hand changes in this release.
