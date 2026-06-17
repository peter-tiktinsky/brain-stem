# Context and memory — how brain-stem frames every session

> **Audience:** anyone who wants the one mental model that ties together everything the assistant "knows" between sessions — written for a reader who has never used Claude Code and has no technical background; every term is glossed on first use. **This doc is canonical for:** the operational-vs-contextual distinction, the difference between durable *context* and the in-session *working window*, and how the memory tiers, the project binders, and the Library all fit into one picture. It is the **map**; the two deep-dives it routes into are **[the memory model](memory-model.md)** (the memory tiers in full) and **[the context library](context-library.md)** (the framing surfaces in full).

---

## The problem, in one line

By default the assistant starts every session **blank** — it remembers nothing about who you are, how you work, or what you did last time. brain-stem fixes that by keeping durable knowledge in plain-text files **on disk** and loading the right pieces back at the start of each session. The question this doc answers is: *what kinds* of durable knowledge are there, and how do they fit together?

---

## Two kinds of durable knowledge

Everything the assistant carries between sessions answers one of **two different questions** — and that split is the whole model.

- **Operational knowledge — guiding logic.** Tells the assistant *how to behave*: your preferences, your conventions, your workflow rules and the lessons behind them. **You author it.** It is the **operating governance** you set — the guiding principles for how the assistant works with you.
- **Contextual knowledge — framing and state.** Tells the assistant *what the work is and where it stands*: the reference that frames a topic, and the record of what has been done. **It accumulates as you work.**

Each kind also has a **scope** — how widely it applies: to one **project**, or **universally** (everything you do). Two questions, two answers each, four cells:

|  | **Operational** — how the assistant should *act* | **Contextual** — what the work *is* and where it *stands* |
|---|---|---|
| **Project** | Semantic + Procedural project memory | Episodic project memory + the **project binder** (+ claude-mem observations, if installed) |
| **Universal** | Global `rules/` + your `CLAUDE.md` | The **Library** |

Read the columns as two jobs: the **left column is governance you write** (how I want the assistant to behave, here and everywhere); the **right column is context that builds up** (what this project is and where it sits, plus reference that applies anywhere).

---

## "Context" is not the working window

One word causes most of the confusion, so pin it down. **Context**, here, means the **durable material that frames the work** — it lives on disk and persists across sessions. That is *not* the same as the assistant's **working window**: the finite attention it holds during one live conversation, which is wiped clean when the session ends.

The relationship is simple: the durable context is the filing cabinet; the working window is the desk. At the start of a session the relevant context is loaded *from the cabinet onto the desk*; when the session ends the desk is cleared, but the cabinet remains. Everything in this doc is the **cabinet** — the durable surfaces. Don't confuse the framing material with the window it is loaded into.

---

## Where each surface sits

The four cells map onto concrete surfaces. This table is the whole system in one view — what each surface is, when it reaches a session, and which deep-dive documents it:

| Surface | Kind · Scope | What it carries | Reaches a session | Detailed in |
|---|---|---|---|---|
| Your `CLAUDE.md` + global `rules/` | Operational · Universal | How you want the assistant to communicate and behave, always | Every session | [memory model](memory-model.md) |
| Semantic + Procedural project memory | Operational · Project | This project's facts, conventions, and workflow rules | Every session in that project | [memory model](memory-model.md) |
| Episodic project memory | Contextual · Project | A high-level record of what each past session did | Every session in that project | [memory model](memory-model.md) |
| The **project binder** | Contextual · Project | A roll-up of every plan in the project — its research, decisions, and handoffs | Cover page every session; the rest on demand | [context library](context-library.md) |
| claude-mem *(optional)* | Contextual · Project | Granular observations from past sessions | Recent ones injected at session start | [memory model](memory-model.md) |
| The **Library** | Contextual · Universal | Durable reference articles, reusable by any project | A pointer surfaced the moment you start researching | [context library](context-library.md) |
| The **Workshop** | Staging | Raw, in-progress research | Never loaded — it feeds the Library | [context library](context-library.md) |

Two things this table makes visible — and they are the points most people miss:

**1. "Memory" is not one thing — it straddles the line.** The formal memory structure holds three tiers, and they do *different jobs*: **Semantic and Procedural** memory are **operational** (they govern behavior), while **Episodic** memory is **contextual** (it records what happened). The **project binder** then continues that contextual job *outside* the formal memory structure — episodic memory and the binder are doing the same kind of work (remembering project state), one inside the memory system and one beside it.

**2. Project state stacks at three granularities.** To answer *"where do we currently sit?"* three contextual surfaces work in concert, coarse to fine: **episodic memory** gives the high-level "what we did last session"; the **project binder** holds the mid-level roll-up (the research index, decision log, and handoff journal across the project's plans); and **claude-mem**, if installed, supplies the granular observations. Together they reconstruct a project's progress and where it stands.

---

## How it all loads

The same accessibility tiering runs through both columns: **what frames or governs *every* session is small and always-on; the bulk waits until it is needed.**

- **Always-on, zero effort:** your universal governance (`CLAUDE.md` + `rules/`), this project's operational memory (Semantic + Procedural), this project's episodic index, and the binder's one-page cover — all loaded at session start.
- **On demand or at the moment of need:** the full binder behind its cover, and the Library (surfaced as a pointer exactly when you begin researching something).
- **Never auto-loaded:** the Workshop, which is staging only.

Nothing that loads automatically is large; the heavy reference and the full project record sit one deliberate step away.

---

## Why this split — evidence & alternatives

The instinct is to treat "memory" as one undifferentiated store and pour everything into it. brain-stem splits it deliberately, for reasons that hold up under scrutiny.

| Decision | Rejected alternative | Why it was rejected |
|---|---|---|
| **Separate operational from contextual** | One "knowledge" store mixing behavior rules and work records | You cannot reason about a pile that conflates *how to act* with *what happened*. Keeping governance separate from state is what lets each be loaded, trusted, and curated on its own terms. |
| **Operational knowledge is authored, not inferred** | Inferring behavior rules from session history | A rule guessed from past transcripts is brittle and unaccountable. The user *declares* the operating governance, so it is explicit and yours to change. |
| **Contextual state is derived from where work happens** | A hand-maintained "project status" you update by hand | A status file kept current by a person rots the moment attention moves on. Deriving the binder from the project's plans means it stays correct with no upkeep. |
| **Three memory tiers, not more or fewer** | A single "notes" tier, or a catch-everything log | The Semantic / Procedural / Episodic split is the long-standing consensus in the study of memory; collapsing it loses the behave-vs-happened distinction, and a catch-everything store drowns its few durable facts in noise. |

The load-bearing principle underneath: **auto-generated and user-authored surfaces survive; hand-maintained status rots.** Operational knowledge survives because *you* own it; contextual state survives because the machine *derives* it. Neither depends on anyone remembering to keep a file up to date.

The three-tier memory basis is grounded in the established study of human memory carried into AI-agent design — Tulving's episodic/semantic split (1972), Cohen & Squire's declarative/procedural split (1980), and their mapping onto language-model agents in the CoALA framework (arXiv:2309.02427) and MemGPT (arXiv:2310.08560). The surface-level evidence — where each surface lives and how it is enforced — is carried in the two deep-dives.

---

## See also

- **[The memory model](memory-model.md)** — the three memory tiers in full: the Semantic / Procedural / Episodic triad, the two scopes, classification, and the promotion pipelines.
- **[The context library](context-library.md)** — the framing surfaces in full: the universal Library, the project binders, the Workshop, and the promotion loop between them.
- **[The governance engine](governance-engine.md)** — how the operating governance you author is read and applied at the moment of every file write.
