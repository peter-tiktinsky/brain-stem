# Release notes — v1.15.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.15.0 is a minor release with no migrations.** Upgrading is a file sync — nothing runs against your plan corpus or your configuration, and nothing needs doing by hand. The widest-reaching change: **the session close-out chain is reliable again, end to end** — it dedupes itself, runs in the right order, is told which session it is closing rather than guessing, and validates clean at the end. Alongside it: manifest validation passes on healthy manifests instead of failing on a shape no writer ever produced, the install stops inventing paths it does not own, the cron-health banner reports the lanes you actually have, and the pipeline that produces this public tree fails closed on provenance vocabulary it has never seen. **Upgrade normally with `install.sh --apply`.**

---

## The headline — session close is reliable, end to end

When a session ends, brain-stem runs a *close-out chain*: it records the session in a chronicle, refreshes indexes, updates the project's plan manifests, and validates the result. Four independent defects in that chain are fixed together in this release, and they compound — which is why they ship as one story.

1. **The idempotency guard runs at the start of the chain, not partway through.** A close-out that fires twice — which schedulers and re-entrant hooks can cause — is now recognized as already-done before any step runs, instead of after some steps have already re-executed.

2. **The chronicle appender recognizes its own work.** Appending a block the chronicle already carries is now a byte no-op, not a second copy. Duplicated chronicle blocks were the visible symptom that led to this investigation.

3. **Two spellings of one directory resolve to one project.** The resolver that decides which project a session belongs to now resolves both endpoints through the real filesystem before comparing, and folds letter-case only when the filesystem says it may. Previously a symlinked or differently-cased path could split one project into two identities — half your records under each.

4. **The detached close is told which session it is closing.** Finishing a close-out is delegated to a short background job. That job used to infer the session's directory from its own working directory — and a job spawned by a scheduler starts in the scheduler's directory, not the session's. The session's own directory is now passed explicitly, and the ambient value is demoted to a fallback.

The failure these produced in combination: a close-out running from the wrong context could duplicate or misfile **another project's** records. That class is closed at its mechanism, not patched at its symptom.

**And the chain now ends clean.** The validation step at the end of every close-out had a standing failure: the schema it validated against described a drift-findings shape that no writer in the system ever produced, so a correct, healthy manifest failed validation at every single close. The schema now states the per-scope shape the writers actually produce, and the close-out receipt flips from a standing error to ok. There is **no data migration** — the data was never wrong; the description of it was.

---

## What else is fixed

**Your checkpoint can no longer be silently overwritten.** Session checkpoints — the state snapshots that let a session resume — now have a single guard that owns the decision to write. A passive re-write clobbering a checkpoint another step had just written is no longer possible.

**Hooks and background jobs no longer wait on input that never arrives.** The previous release fixed the first instance of a background job blocking forever on an input stream that never closes. This release completes the family: every confirmed input-reading site in the shipped hook surface now bounds its read, and the convention is gated — a new unbounded read fails the verification suite rather than shipping.

**The install does not invent paths it does not own.** A sweep of the shipped surface removed defaults that pointed into a home directory the install does not control. The vault location is resolved from your recorded configuration; when no vault is configured, the tools now refuse with a clear message instead of silently adopting a guess. The portability check that catches this class was widened from a founding subset to the full shipped roster, so a new occurrence fails verification.

**The cron-health banner reports the lanes you actually have.** The banner that warns about stale background lanes now derives its roster from what is actually registered on your machine instead of a fixed list, and it distinguishes lane types — so a lane that is healthy, or absent by design, no longer produces a false staleness warning.

**Governance internals describe themselves truthfully.** Three smaller fixes in the same spirit: the write-guard reads the naming rules at the path where they actually live; the project scaffolder no longer stamps document types the allowlist does not carry; and the manifest-recording helper writes the schema shape it declares instead of coercing it.

**Shipped comments resolve better for you.** The unresolvable compound register citations across the shipped comment surface — cross-references only the maintainer's machine could resolve — are reworded to state the durable fact inline. A small residue of older build-era references remains and shrinks release over release; the release pipeline now gates new ones.

---

## Smaller changes worth knowing

- **Manifest text keeps its characters.** Manifest re-serializers now write non-ASCII text as-is instead of escaping it, so quotes, dashes, and accented characters in plan text survive a round-trip readably. Files written by earlier versions are re-serialized the next time they are touched; nothing rewrites them proactively.
- **Schema examples are anonymous.** Two schema examples that carried real machine identifiers now carry placeholder ones. The shipped behavior is unchanged.
- **The librarian manifest skeleton is complete.** The template a new install seeds now carries every required root, so a fresh manifest validates without a first-touch heal.
- **The migration lane can say "ran, but deferred."** A migration that correctly determines it has nothing to do on your install now records that outcome distinctly, instead of being indistinguishable from one that never ran.

---

## The release pipeline itself

A substantial share of this release hardens the pipeline that produces the public tree you download. It is maintainer-side machinery, summarized here for honesty rather than action:

- A provenance-token family the pipeline has never seen is now **flagged by default** — the completeness oracle inverts the old posture, where only known vocabulary was caught.
- Every strip-family is measured across its variant axes (case, separator, suffix shapes), with the measurement recorded per family — an axis with no recorded verdict is an axis nobody measured, and that is now visible.
- Every changed public file must propagate to the ship tree or the gate fails — an unported or stale member is a hard stop, not a silent omission.
- The blind reviewers that verify builds now probe their own tools first, so a missing search binary degrades loudly into a declared fallback mode instead of silently weakening verification.

None of this changes runtime behavior on your install. It changes how much you can trust what reaches you.

---

## Work in this release you will not see listed

This release also carries a large body of work on brain-stem's own internal test infrastructure — converting fixtures that froze whole-file snapshots into structure-derived assertions, isolating tests from the live machine they run on, and retiring dead helpers. None of it ships: it lives in the development repository's test tree, which is excluded from the published surface. It is mentioned so the release does not look smaller than it was.

---

## Upgrading

**No migrations ship in this release.** Upgrade normally:

```bash
bash install.sh            # preview — prints what would change and any required flags
bash install.sh --apply    # apply
```

After applying, your install reports `v1.15.0` and behaves as described above from the next session onward. No hand-steps, no corpus rewrites, nothing to verify beyond the installer's own summary.
