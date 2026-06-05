# governance/baselines/ — per-release foundation-manifest archive

**In-place upgrade engine: legacy-adopt floor reconstruction.**

This directory archives one `foundation-manifest-<version>.json` per shipped
release. Each archived manifest is a **byte-identical frozen copy** of the
`governance/foundation-manifest.json` that shipped in that release (its per-file
`{path, sha256, size, mode}` set). The archive is the historical-sha source the
in-place upgrade engine consults when reconstructing a **legacy adopter's** floor
(an adopter who force-installed an older brain-stem that predates the engine and
therefore has no `governance/.installed-state.json` stamp).

## Release-cut mint step (release-ceremony contract)

At every release cut, **mint** the new version's baseline into this directory:

```
cp -f governance/foundation-manifest.json \
      governance/baselines/foundation-manifest-<version>.json
```

where `<version>` is the `.version` field of the just-regenerated
`governance/foundation-manifest.json` (e.g. `v1.0.2`). Commit the minted archive
with the release. This is a new, explicit release-ceremony step introduced by the
upgrade engine, and is the per-version sha256 floor for the legacy-adopt and
three-way-base machinery.

## Floor-match is a v2 optimization (today: v0.0.0 + full migration chain)

The engine's `install.sh` legacy-adopt path would (in v2) reconstruct the
adopter's effective installed version by sha256-matching her on-disk foundation
files against the archived manifests here and picking the highest version whose
file set her disk satisfies (the "best-effort floor"). **That floor-match requires
BOTH >= 2 archived baselines (to establish a meaningful range) AND the v2 matching
logic** — and that matching logic is **not yet implemented**. It is therefore a
**v2 optimization**.

Baselines accrue one frozen manifest per release-cut (the mint step above), so
`>= 2` archived baselines exist from the **second** release onward. The count
alone does **not** activate floor-match — the unbuilt v2 logic is the remaining
gate, so the `v0.0.0` full-chain path holds at **any** baseline count until that
logic ships. Until then the **sole operative path** (the legacy-adopt path) is
`v0.0.0` + the **full idempotent migration chain from 0001** (the Flyway
bootstrap-from-empty property — every migration is authored to tolerate the
oldest/empty precondition, so over-running is safe). In this lane `install.sh`
keeps `INSTALLED_VERSION="(none)"`, the migration runner normalizes the floor to
`v0.0.0`, runs the full chain without `min_from`-skipping (`FLOOR_IS_REAL=0`), and
every FOUNDATION-REPLACE managed-set file defaults to **take-new** (so the
fixes land) — never the `cp -n` skip that silently dropped the fix. The legacy
adopter's on-disk bytes are snapshotted to `<file>.foundation-local` only when
they differ from BOTH the new upstream AND every reachable historical sha in these
archives (an adopter edit worth preserving; dpkg `.dpkg-old`).
