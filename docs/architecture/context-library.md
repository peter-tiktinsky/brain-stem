# The context library — universal and project context surfaces

> **Audience:** anyone who wants the framing surfaces in full — written for a reader who has never used Claude Code and has no technical background; every term is glossed on first use. **This doc is canonical for:** the Library, the Workshop, the project binder, and the promotion loop between them. For the bigger picture of how these fit with the memory tiers — the operational-vs-contextual model and what "context" means — read **[Context and memory](context-and-memory.md)** first; this page is the deep-dive on the **contextual** surfaces it introduces.

---

These are the surfaces that hold **contextual knowledge** — the durable material that *frames the work*, as opposed to the operating governance that tells the assistant how to behave (covered in [the memory model](memory-model.md)). There are two, by scope:

- the **Library** — *universal* context: durable reference any project can draw on;
- the **project binder** — *project* context: a roll-up of one project's plans.

A third surface, the **Workshop**, is not context you read — it is the staging bench where research happens before it is promoted into the Library. Each surface has exactly one home, and none lives inside the folder Claude Code itself occupies or inside your synced notes proper — the reasons are under [Why this design](#why-this-design-evidence-alternatives).

---

## The Library — universal context

The **Library** is the reading room: durable reference that applies to *any* project. Each piece of knowledge is **one article, one concept** — a short markdown file that declares, in its header, that it is reference material (`type: reference`). Articles are grouped into topic folders, and every topic folder plus the library root carries an index file (`_index.md`) so the shelf is always labeled.

Two supporting parts keep it trustworthy:

- **An immutable raw copy.** When an article is created, the source material it was distilled from is kept *unchanged* in a `_raw/` sub-folder. The polished article can be rewritten freely; the raw record of where it came from never is.
- **A single change log.** One file (`log.md`) records one line per library event — an article added, updated, or superseded — so there is one place to see what changed and when.

You see the Library in your notes app as a folder named **`Wiki/`**, which points straight at it. (The raw path is hidden from your notes app's search so you read the clean `Wiki/` view, not two copies.)

**How it loads — at the moment of need.** The Library is *not* read into every session; a full reference shelf loaded every time would be enormous and mostly irrelevant. Instead, when your first request in a session looks like research, a small background check notices, consults the library index, and quietly surfaces a one-line pointer: *there may already be reference on this, and here is how to read it.* It never blocks you and stays silent when the Library is empty. The right reference is offered exactly when you are about to need it, and never otherwise.

---

## The Workshop — the staging bench

The **Workshop** is the messy bench out back: raw, in-progress research with **no required format and no rules**, because forcing structure onto scratch paper only slows the work. It is **ephemeral and never loaded** — nothing in it is read into a session automatically or indexed, and it has no view in your notes app on purpose (the bench is not the reading room). It lives in the system's short-lived working-state folder, and it is read at exactly one moment: when a finished piece is promoted out of it.

## The promotion loop — bench to shelf

The Workshop and the Library are two ends of one motion. Raw research lands on the bench; when a piece settles into something reusable, it is **promoted** onto the shelf — and promotion is a transformation, not a copy:

1. **Scrub.** A promotion routine strips out everything specific to the one project that produced the draft — its names, dates, and one-off details — leaving the general, reusable truth. This **scrub is the gate:** a draft that is nothing *but* project-specific detail has nothing left after scrubbing, so it never becomes a universal article.
2. **Preserve the source.** The original, unscrubbed material is filed unchanged into the article's `_raw/` copy.
3. **Shelve and index.** The scrubbed article is written into its topic folder, the indexes are regenerated, and the change is recorded in the log.

The plain version: **the Workshop is where you think; the Library is what you keep.**

---

## The project binder — project context

A **project binder** is the ring binder for a single project: a roll-up of *every plan that belongs to that project*. A **plan** is one multi-step project folder — its goal, task list, research, and decisions (see **[Plans](plans.md)**); a project typically accumulates several over its life, and the binder gathers them into one view.

**Membership is automatic.** Each plan's control file names the project it belongs to; every plan naming this project — with its sub-plans grouped underneath by lineage — is gathered in, with no roster to maintain by hand. The binder is re-derived from the plans themselves on each pass, so it holds a few standard pages, all **generated, never hand-written:**

- a **cover page** (`hub.md`) — the project's identity, its plan IDs and status, and pointers into everything below;
- a **research index** — the research recorded across all the project's plans, organized by plan, with a link straight into each plan's research folder;
- a **decision log** — the decisions across all the project's plans, rolled into one cross-plan list;
- a **handoff journal** — the session-handoff records across the project's plans, newest-first, so the next session can pick up where the last left off.

The binder **does not hold the plans' contents — it indexes them**, with links back to the canonical plan folders. You see all the binders in your notes app under **`Projects/`**. Its **cover page loads at the start of every session in that project**; everything behind the cover is reached on demand by following a pointer from it.

---

## How a project is identified — the launch directory

All of this depends on one question: *which project am I in?* brain-stem answers it the simplest way — **a project is the directory you launched the assistant from.** When you start Claude Code inside a folder, that folder *is* the project's identity (the home directory is treated as a project named `home`). Both project-scoped surfaces key off it: this project's memory and this project's binder are selected by the launch directory, every time. There is **no list of projects to maintain** — the location you started in selects everything project-scoped, automatically.

> **Why launch-directory, not a declared list?** A hand-maintained roster of "what counts as a project" drifts out of date the moment you forget to update it. Deriving the project from where you launched means there is nothing to keep in sync — the identity is read fresh from reality each session.

---

## Why this design — evidence & alternatives

For *why these are split from the operating-governance surfaces at all*, see [Context and memory](context-and-memory.md). This section covers the choices specific to the framing surfaces: **where they live, and how the Library hint is enforced.** The principle underneath every row is that **auto-generated surfaces survive while hand-maintained ones rot** — so each surface is derived, and indexes are regenerated rather than tended.

| Decision | Rejected alternative | Why it was rejected |
|---|---|---|
| **Homes in the plan area / working-state folder** | Putting surfaces inside the tool's own config folder (`~/.claude/…`) | That folder is protected by a rule that blocks edits to sensitive files, so a script trying to *write* reference there fails unreliably. A store you cannot reliably write to is not a store. |
| **Homes outside your synced notes folder** | Putting the durable surfaces inside the notes vault proper | A notes folder is one setting away from cloud sync, where silent file-edit failures are a known hazard (Claude Code issue **#52493**). The surfaces stay out of any sync boundary; you get a read-only *view* (`Wiki/`, `Projects/`) instead. |
| **Workshop and Library as separate places** | One folder holding raw notes *and* finished reference | Mixing in-progress scratch with shelved reference buries the reference; surveys of real setups found no durable two-in-one store — each collapsed to one canonical home or degraded into scatter. |
| **Promotion scrubs project detail** | Copying workshop notes to the Library verbatim | An "universal" article still carrying one project's names and dates is project leftovers on the wrong shelf. The scrub is the gate that keeps the shelf reference-grade. |
| **Project identity = launch directory** | A declared roster of projects | A hand-maintained membership list is exactly the relationship metadata that goes stale unattended. |
| **The Library hint is an advisory prompt-time nudge** | Enforcing "check the Library first" via a written rule, a blocking step, or an after-the-fact check | A standing written instruction **degrades over a few sessions** and gets rationalized away under pressure (Claude Code issue **#33603**); an after-the-action check fires too late to prevent duplicate research; and the after-action hook channel that could carry such a reminder cannot inject context (Claude Code issue **#18427**). A prompt-time nudge is the only vehicle that fires *before* research begins without blocking it. |

These enforcement-posture choices are each anchored to a publicly documented Claude Code failure mode — issues **#52493** (silent edit failure inside a sync boundary), **#33603** (a standing rule degrading over successive sessions), and **#18427** (the after-action hook channel being unable to inject context) — rather than to preference. The result is a context library that holds the right reference in the right place, offers it at the right moment, and **stays correct even when no one is tending it.**

---

## References

Each item below is **adopter-present** — it ships with the install or is generated at runtime. These surfaces start empty on a fresh install and fill as you work.

- `~/.claude-plans/_library/` — the universal Library: topic folders of one-concept `type: reference` articles, each topic and the root carrying an `_index.md`; immutable source copies under `_raw/`; a single `log.md` change log. Surfaced in the vault as the `Wiki/` view.
- `~/.claude-plans/_projects/<project>/` — the project binders, each rolled up from **every plan whose control file names that project**: `hub.md` (the eager cover page, carrying the project's plan IDs and status), plus the research index (organized by plan, with a per-plan link into each plan's research folder), the cross-plan decision log, and the handoff journal — reached on demand. Surfaced in the vault as the `Projects/` view.
- The **Workshop** — a per-topic staging area in the system's working-state folder (resolved at runtime, never a hardcoded path); ephemeral, never loaded or indexed, read only at promotion.
- The **moment-of-need Library hint** — a session-input background check that detects research intent and surfaces a one-line library-coverage pointer; advisory only, never blocks, silent when the Library is empty.
- The **promotion (scrub) routine** — the librarian step that strips project-specific detail from a workshop draft, preserves the raw source, and shelves the scrubbed article.
- Companion docs: **[Context and memory](context-and-memory.md)** (the operational-vs-contextual model) and **[the memory model](memory-model.md)** (the memory tiers and scopes).
- Publicly documented Claude Code failure modes grounding the enforcement-posture choices: issues #52493 (edit silent-fail inside a sync boundary), #33603 (a standing rule degrading over successive sessions), and #18427 (the after-action hook channel unable to inject context).
