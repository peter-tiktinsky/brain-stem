# Onboarding

> **Audience:** an adopter about to run first-run setup, or anyone who wants to know exactly what `/onboard` does before they type it — written for someone who has never used Claude Code and has no technical background. Every term is explained the first time it appears.

After you have [installed the foundation](index.md#step-1-install-the-foundation), all the moving parts are in place but nothing is personalized yet. The system does not know who you are, where you want your notes kept, or how you like to be spoken to. **Onboarding is the one-time guided setup that fills those gaps.** You type one command, answer a short interview, and the system writes down your preferences and builds your vault.

Think of it as the setup wizard a new app shows you the first time you open it — except this one also builds your filing cabinet and writes down your preferences so the assistant remembers them across every future conversation.

---

## You type it; it never fires on its own

You start onboarding by typing one command in a Claude Code session:

```
/onboard
```

`/onboard` is a **skill** — a named capability you trigger with a slash. Most skills can be started two ways: you type them, *or* the assistant decides on its own that the moment calls for it. Onboarding is deliberately set so the assistant can **never** start it by itself. Only a human typing `/onboard` begins it.

The reason is safety: onboarding writes your personal files and builds your vault, so it must never surprise you by running unprompted in the middle of unrelated work. The skill is still fully visible in the menu — it is just muted from auto-firing.

---

## The two-part interview

The interview is short and split into two parts, on purpose.

### Section A — the confirmation card

The system has already looked up the obvious facts and simply shows them to you to confirm or correct:

| Field | Where it comes from |
|---|---|
| Name | Your git settings |
| Email | Your git settings |
| Timezone | Your operating system |
| Vault location | A proposed default folder for your new vault |

You press Enter to accept everything, or a number to edit a single field. No typing is required unless something is wrong. This is mechanical fact-gathering the computer can do for you, so it does not waste your time.

### Section B — in your own words

This is the only part where *you* describe who you are and how you work:

- Your role and organization
- How you want the assistant to communicate with you
- How you want it to collaborate
- Your tools and field of work

Write loosely and at length — the system reads your answer and condenses it into a few short, labeled fields (your role, your organization, and three preference blocks). Everything in Section B is **optional**; skip anything that does not apply. This split matters because Section A is fact-gathering a computer can do, while Section B is the genuinely human input no lookup can guess.

> Section B captures your **written** answer in the shipped setup flow. A spoken-voice option is a possible future addition, not part of the flow today.

---

## What onboarding produces

From your answers, onboarding writes three things:

| Output | What it is | Where it lands |
|---|---|---|
| **A settings file** | A small, structured record of your answers — name, email, timezone, vault location, role, preferences | `~/.claude/user-manifest.json` |
| **A personal-preferences file** | A plain instructions file the assistant reads at the start of *every* session | `~/.claude/CLAUDE.md` |
| **A brain vault** | A fresh, pre-built notes folder, ready to open in Obsidian | a folder you chose (default under `Documents/`) |

The settings file is the single record of who you are: every other part of the system reads your details from there rather than re-asking you. Before it is saved, it is checked against a strict blueprint — if the data does not fit, the write is refused rather than saved broken — and it is written **atomically**, meaning the new version is swapped into place in one instant so you never end up with a half-written, corrupted file.

### The two `CLAUDE.md` files

A `CLAUDE.md` file is a plain instructions file the assistant reads **automatically** when it starts working — a standing note it re-reads every session. Onboarding authors two of them, with different jobs:

| File | What it holds | What it is about |
|---|---|---|
| **The global file** (`~/.claude/CLAUDE.md`) | Your identity plus three preference blocks (communication, working style, tools & field) | **You as a person**, across all your work |
| **The vault file** (at the top of your new vault) | A map of the vault's folder structure | **The layout** of one notebook |

Both start as **templates** — finished documents with blanks like `{{IDENTITY_NAME}}` — and onboarding fills every blank with your real values. As a safeguard, before either file is saved the system scans the finished text for any leftover `{{...}}` blank and **refuses to write the file if even one remains.** You never end up with a `CLAUDE.md` that literally says `{{IDENTITY_NAME}}` to the assistant. It is the difference between a mail-merge letter that says "Dear Jane" and one that embarrassingly still says "Dear `[FIRST NAME]`".

---

## Your vault, built for you

brain-stem ships a **seed** — a small starter folder tree with the standard folders every brain vault has. Onboarding copies that seed into the location you chose and turns it into your working vault. This is called **adopt-by-default**: you do not opt in to the standard structure as an extra step; you get it automatically.

The seed gives you:

| Folder | What it is for |
|---|---|
| **`Vault Writers/`** | A catalog of every automated system that writes into your vault. |

The copy is gentle and safe to repeat: it walks the seed file by file and **skips anything already present**, so re-running setup never overwrites your work. While building the vault, onboarding also wires five convenience shortcuts into it — pointing at your plans area, your installed skills, the universal Library, the project binders, and your deliverable work area — so all five appear inside the vault without copying anything.

### The open-in-Obsidian beat

Building a folder is invisible, so onboarding does not silently finish. It prints a clear next action:

> Open it in Obsidian (Open folder as vault) → select your vault path. Confirm when done.

This explicit hand-off is deliberate: the system makes the filing cabinet, then hands you the key and tells you which drawer to open first.

---

## The optional add-ons — recommended, never required

The last step offers two optional extras and recommends them honestly without ever blocking you:

| Add-on | What it does | Why it is recommended |
|---|---|---|
| **claude-mem** | An optional plugin that gives the assistant broad automatic recall *on top of* brain-stem's own curated memory | The system is fully functional without it — the recommendation says so plainly. |
| **GitHub** | A backup service that gives your vault full version history and lets you recover or sync across machines | Protects your work from any mistake. |

For each, the system checks whether you already have it, gives a strong recommendation with the honest reason and the exact command to set it up, and offers a frictionless "skip and do it later — the rest of your setup still works." It records your choice but never forces it. Set up both, neither, or one, and your setup still works coherently.

---

## Run once — and how to safely re-run

Onboarding is designed to run **once** and then get out of the way. The moment setup completes, the system records a small "onboarding finished" marker. After that, typing a plain `/onboard` again does nothing — it prints `Onboarding already complete — nothing to do` and exits without touching anything. This protects your personalized files from being wiped by a careless second run.

If you genuinely want to change course, two flags make it explicit:

| You type | What happens |
|---|---|
| `/onboard` (after setup is done) | No-op. Prints "already complete," exits. Nothing is touched. |
| `/onboard --resume` | Picks up an *unfinished* setup where you left off. |
| `/onboard --force` | The deliberate "yes, I really mean redo this" override. Re-runs the full setup. |

Even with `--force`, your edits are protected. If a `CLAUDE.md` already exists and differs from what would be freshly generated, the system does not overwrite it — it writes the proposed new version off to the side, shows you the differences, and leaves your real file untouched until you decide. The whole of setup follows one safety rule, **block-and-log**: if anything goes wrong — bad data, a failed check, a disk error — it stops and reports the failure instead of saving something broken. It never writes a half-finished file and hopes.

---

## A gentle reminder until you are done

If you install brain-stem but have not yet finished onboarding, the assistant surfaces a one-line banner at the start of each session inviting you to run `/onboard --resume` and pick up where you left off. Once setup completes, that banner disappears for good. It never blocks you from working and never forces the command — it only offers. It is the "finish setting up your account" nudge a well-designed app shows until you complete onboarding, then stops bothering you forever.

---

## See also

- **[Core concepts](concepts.md)** — the mental model behind everything onboarding just set up.
- **[Onboarding (architecture)](../architecture/onboarding-lifecycle.md)** — the full, under-the-hood explanation: the settings blueprint, the template substitution, the no-residue and no-clobber guarantees, and exactly which scripts run when.
- **[Packaging & runtime](../architecture/packaging-runtime.md)** — how the foundation got onto your machine in the first place, and how to reverse it safely.
