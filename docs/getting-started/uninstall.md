# Uninstalling

> **Audience:** anyone who wants to remove brain-stem and needs to know exactly what gets deleted, what is kept, and how to recover if something looks wrong — written for someone with no technical background. Every term is explained the first time it appears. For *why* uninstall behaves this way, see [Packaging & runtime](../architecture/packaging-runtime.md).

Removing brain-stem is one command. The important thing to understand first is what it will and will not touch — because the uninstaller is deliberately careful: it removes **only the untouched files it originally installed**, backs everything up before it starts, and leaves your notes and any file you edited alone.

---

## The command

Run the uninstaller that shipped with your install:

```bash
bash ~/.claude/uninstall.sh
```

That is the whole operation. There is no separate confirmation flag to learn. What happens next is described below so there are no surprises.

---

## What it does, step by step

1. **It checks that this is really a brain-stem install.** The installer left a dated record (a *provenance log*) in `~/.claude/logs/` proving an install happened and naming the folder it wrote to. The uninstaller reads that record and confirms the folder you are removing matches. **If there is no install record, it refuses** — on the principle that you should not "reverse" an install that was never made.

2. **It backs everything up first.** Before removing a single file, it copies the entire install folder into a timestamped backup named `.pre-uninstall-<timestamp>/`. This is the safety net: even an unexpected outcome is fully recoverable from that copy.

3. **It removes files one at a time, checking each.** For every file the install originally laid down, the uninstaller re-computes that file's *fingerprint* (a signature of its exact contents) and compares it to the receipt recorded at install time:
   - **Unchanged** — the file is exactly as shipped → it is removed.
   - **Edited by you** — the contents differ from what was shipped → it is **kept**.

   So your personal edits survive by default. The uninstaller only deletes files it is certain you never touched.

4. **It stops brain-stem's background jobs — and only those.** Every scheduled job brain-stem creates is named starting with `com.brain-stem`. The uninstaller stops and removes only jobs in that reserved name-space. If it ever finds a job whose name merely *looks* similar but sits outside that prefix, it aborts rather than risk stopping something unrelated (your backup stays intact).

---

## What is preserved

- **Your vault.** Your notes folder is yours; uninstall does not delete it.
- **Anything you edited.** Any shipped file you changed is left in place (see step 3).
- **Your accumulated working data.** brain-stem keeps the *program* and the *data it generates* in separate places on purpose — durable data under `~/.local/share/brain-stem` and disposable working state under `~/.local/state/brain-stem`. Uninstalling the program does not endanger that data.
- **The install/uninstall record.** The `~/.claude/logs/` provenance log is kept, so there is always a trail of what happened.

---

## Good to know

- **There is no dry-run / preview for uninstall.** Unlike the installer — whose default *is* a write-free preview — the uninstaller does not show you a plan first. The mandatory backup taken in step 2 is the safety mechanism instead. Expect it to back everything up, not to rehearse.
- **If something looks wrong afterward,** everything the uninstaller removed is in the `.pre-uninstall-<timestamp>/` backup folder it made before starting. Nothing is gone for good.
- **Reinstalling later** is the same first-time path as before: clone, preview, `--apply`. See [Getting started](index.md).
