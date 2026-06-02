#!/bin/bash
# mem-promote/scripts/prefilter.sh — standalone gather + dedup prefilter.
#
# Phase 1+2 of the mem-promote pipeline: read claude-mem
# observations for the named session(s), cluster by Jaccard token overlap, and
# de-conflict each cluster against the curated memory/*.md file set. Emits
# ranked candidates with up to ≤8 neighbors (capture floor Jaccard ≥0.20).
# Claude (the SKILL.md pipeline) does the LLM-reasoned A.U.D.N.+NARROW reshape +
# semantic CONFLICT routing on top of these candidates, then buffers proposals
# to the review queue via enqueue_item.
#
# PROPOSE-THEN-CONFIRM ONLY: this prefilter NEVER writes memory files. With
# --enqueue it buffers proposal items into the review queue (still propose-only);
# default is NDJSON to stdout for the LLM reshape step.
#
# Graceful degradation: claude-mem DB absent → 0 candidates → clean exit
# status "n/a" (exit 0, no error). The prefilter is strictly additive.
#
# Standalone: NO librarian-lib dependency. Resolves the memory
# dir via hooks/lib/paths.sh when present, else a sane default.
#
# Bash 3.2 clean (R-23). Argv-based Python heredoc (no stdin pipe to the heredoc).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve install root: skills/mem-promote/scripts → up 3 = $CLAUDE_HOME.
CLAUDE_HOME_GUESS="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$CLAUDE_HOME_GUESS}"

PATHS_SH="$CLAUDE_HOME/hooks/lib/paths.sh"
[ -r "$PATHS_SH" ] && source "$PATHS_SH"

SESSIONS=""
SESSION_GLOB=""
DRY_RUN="false"
ENQUEUE="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSIONS="${SESSIONS}:$2"; shift 2 ;;
    --session-glob) SESSION_GLOB="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --enqueue) ENQUEUE="true"; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "mem-promote/prefilter: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$SESSIONS" ] && [ -n "${MEM_SESSION_PATH:-}" ]; then
  SESSIONS="${MEM_SESSION_PATH}"
fi
if [ -n "$SESSION_GLOB" ]; then
  for f in $SESSION_GLOB; do
    [ -f "$f" ] && SESSIONS="${SESSIONS}:${f}"
  done
fi
SESSIONS="${SESSIONS#:}"

if [ -n "${MEMORY_DIR:-}" ]; then
  : # caller override wins
elif command -v resolve_memory_dir >/dev/null 2>&1; then
  MEMORY_DIR="$(resolve_memory_dir)"
else
  MEMORY_DIR="$CLAUDE_HOME/projects/_global/memory"
fi
case "$MEMORY_DIR" in
  */) : ;;
  *) MEMORY_DIR="$MEMORY_DIR/" ;;
esac

CLAUDE_MEM_DB="${CLAUDE_MEM_DB:-$HOME/.claude-mem/claude-mem.db}"
# Capture floor widened to ≥0.20; ≤8 ranked neighbors per candidate.
CLUSTER_THRESHOLD="${MEM_PROMOTE_CLUSTER_THRESHOLD:-0.20}"
NEIGHBOR_CAP="${MEM_PROMOTE_NEIGHBOR_CAP:-8}"

# No-claude-mem-DB graceful degradation. DB absent → status n/a, 0
# candidates, clean exit. This is the dead-but-harmless contract — never
# an error, never a non-zero exit.
if [ ! -f "$CLAUDE_MEM_DB" ]; then
  echo "mem-promote: claude-mem DB absent at $CLAUDE_MEM_DB — status=n/a candidates=0 (claude-mem integration is optional; foundation floor complete without it)" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "mem-promote: status=n/a sessions=0 scanned_obs=0 candidates=0"
  fi
  exit 0
fi

if [ -z "$SESSIONS" ]; then
  echo "mem-promote: no sessions specified (use --session, --session-glob, or MEM_SESSION_PATH)" >&2
  exit 0
fi

# Phase 1+2: gather + cluster + dedup. Emits NDJSON candidate lines (one per
# cluster) carrying ≤NEIGHBOR_CAP ranked existing-memory neighbors.
python3 - "$SESSIONS" "$MEMORY_DIR" "$CLAUDE_MEM_DB" "$DRY_RUN" "$CLUSTER_THRESHOLD" "$NEIGHBOR_CAP" <<'PY'
import hashlib, json, os, re, sqlite3, sys

sessions_raw = sys.argv[1]
memory_dir = sys.argv[2]
db_path = sys.argv[3]
dry_run = (sys.argv[4] == "true")
try:
    cluster_threshold = float(sys.argv[5])
except ValueError:
    cluster_threshold = 0.20
try:
    neighbor_cap = int(sys.argv[6])
except ValueError:
    neighbor_cap = 8

session_paths = [p for p in sessions_raw.split(":") if p]

STOP_WORDS = set(("the a an of to for and or with in on at by from is are was were "
                  "be been being manually auto automatically new old via using "
                  "after before into out as but not so than then also this that these those "
                  "shipped added created built extracted fixed updated changed introduced "
                  "landed implemented resolved initiated wired flipped verified validated "
                  "documented archived marked written decomposed complete completed finished "
                  "done now next all any some each both more less most least same other").split())

def candidate_id(subject):
    h = hashlib.sha256(("mem-promote|promotion-candidate|%s" % subject).encode("utf-8")).hexdigest()
    return h[:16]

def tokens_of(text):
    if not text:
        return set()
    t = re.sub(r'[^a-z0-9]+', ' ', text.lower())
    return set(w for w in t.split() if len(w) >= 3 and w not in STOP_WORDS)

def normalize_title(title):
    t = re.sub(r'[^a-z0-9]+', ' ', (title or "").lower().strip())
    return re.sub(r'\s+', ' ', t).strip()

def subject_hash(title):
    return hashlib.sha256(normalize_title(title).encode("utf-8")).hexdigest()[:16]

def parse_fm_title(path):
    try:
        t = open(path).read()
    except Exception:
        return "", ""
    if not t.startswith("---"):
        return "", ""
    end = t.find("\n---", 3)
    if end == -1:
        return "", ""
    name, desc = "", ""
    for line in t[3:end].split("\n"):
        m = re.match(r'^(name|description)\s*:\s*(.*)$', line.strip())
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                v = v[1:-1]
            if m.group(1) == "name":
                name = v
            else:
                desc = v
    return name, desc

existing = []
if os.path.isdir(memory_dir):
    for fn in sorted(os.listdir(memory_dir)):
        if not fn.endswith(".md") or fn == "MEMORY.md":
            continue
        full = os.path.join(memory_dir, fn)
        if not os.path.isfile(full):
            continue
        name, desc = parse_fm_title(full)
        title = name or re.sub(r'^(user_|feedback_|project_|reference_|episode_)', '', fn[:-3]).replace("_", " ")
        existing.append((fn, title, tokens_of(title + " " + desc)))

try:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
except Exception as e:
    # Even with a present-but-unopenable DB, degrade to status n/a (additive).
    sys.stderr.write("mem-promote: cannot open claude-mem DB (%s) — status=n/a\n" % e)
    if dry_run:
        print("mem-promote: status=n/a sessions=0 scanned_obs=0 candidates=0")
    sys.exit(0)

def session_id_from_path(p):
    base = os.path.basename(p)
    return base[:-6] if base.endswith(".jsonl") else base

def memory_session_for(csid):
    cur = conn.cursor()
    try:
        cur.execute("SELECT memory_session_id, completed_at FROM sdk_sessions WHERE content_session_id=?", (csid,))
    except Exception:
        return None, ""
    row = cur.fetchone()
    return (row["memory_session_id"], row["completed_at"] or "") if row else (None, "")

def observations_for(msid):
    cur = conn.cursor()
    try:
        cur.execute("SELECT id,type,title,subtitle,facts,narrative,created_at FROM observations WHERE memory_session_id=? ORDER BY id ASC", (msid,))
    except Exception:
        return []
    return list(cur.fetchall())

all_obs = []
for sp in session_paths:
    csid = session_id_from_path(sp)
    msid, ended = memory_session_for(csid)
    if not msid:
        continue
    for o in observations_for(msid):
        title = (o["title"] or "").strip()
        if not title:
            continue
        subtitle = (o["subtitle"] or "").strip()
        narrative = (o["narrative"] or "").strip()
        passage = title + ((" — " + subtitle) if subtitle else "")
        if narrative:
            passage += "\n\n" + narrative[:600]
        all_obs.append({"session_id": csid, "session_end": ended, "id": o["id"],
                        "type": o["type"], "title": title, "subtitle": subtitle,
                        "created_at": o["created_at"], "passage": passage,
                        "tokens": tokens_of(title + " " + subtitle)})
conn.close()

def jaccard(a, b):
    if not a or not b:
        return 0.0
    uni = a | b
    return len(a & b) / float(len(uni)) if uni else 0.0

# Union-find cluster by Jaccard ≥ threshold.
parent = list(range(len(all_obs)))
def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]; x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb: parent[rb] = ra

token_index = {}
for i, o in enumerate(all_obs):
    for t in o["tokens"]:
        token_index.setdefault(t, []).append(i)
seen = set()
for t, idxs in token_index.items():
    if len(idxs) < 2 or len(idxs) > 200:
        continue
    for i in range(len(idxs)):
        for j in range(i+1, len(idxs)):
            a, b = sorted((idxs[i], idxs[j]))
            if (a, b) in seen:
                continue
            seen.add((a, b))
            if jaccard(all_obs[a]["tokens"], all_obs[b]["tokens"]) >= cluster_threshold:
                union(a, b)

clusters = {}
for i in range(len(all_obs)):
    clusters.setdefault(find(i), []).append(i)

emitted = 0
for cluster_idxs in sorted(clusters.values(), key=lambda c: all_obs[c[0]]["created_at"] or ""):
    cobs = [all_obs[i] for i in cluster_idxs]
    rep = min(cobs, key=lambda o: len(o["title"]))
    subject = rep["title"]
    ctoks = set()
    for o in cobs:
        ctoks |= o["tokens"]
    # Rank ALL existing neighbors by Jaccard ≥ capture floor; keep top ≤cap.
    scored = []
    for fn, title, etoks in existing:
        sc = jaccard(ctoks, etoks)
        if sc >= cluster_threshold:
            scored.append({"file": fn, "subject_hash": subject_hash(title), "match_score": round(sc, 2)})
    scored.sort(key=lambda d: d["match_score"], reverse=True)
    neighbors = scored[:neighbor_cap]
    best = neighbors[0]["match_score"] if neighbors else 0.0
    dedup = "duplicate" if best >= 0.6 else ("variant" if best >= 0.35 else "novel")
    sessions_seen = {}
    for o in cobs:
        sessions_seen.setdefault(o["session_id"], o["session_end"])
    sessions_sorted = sorted([{"session_id": s, "session_end": e} for s, e in sessions_seen.items()],
                             key=lambda s: s["session_end"] or "")
    candidate = {
        "capability": "mem-promote",
        "check": "promotion-candidate",
        "candidate_id": candidate_id(subject),
        "subject": subject,
        "classification_hint": dedup,
        "evidence": {
            "sessions": sessions_sorted,
            "observations": [o["passage"] for o in sorted(cobs, key=lambda o: o["created_at"] or "")[:6]],
            "cluster_size": len(cobs),
            "deconflicted_against": neighbors,
            "pair_confirmed": len(sessions_sorted) > 1,
        },
        "provenance": {"source": "claude-mem", "source_observation_id": rep["id"]},
        "notes": "%s candidate; %d ranked neighbor(s) (Jaccard floor %.2f)" % (dedup, len(neighbors), cluster_threshold),
    }
    print(json.dumps(candidate, ensure_ascii=False))
    emitted += 1

if dry_run:
    print("mem-promote: status=ok sessions=%d scanned_obs=%d clusters=%d candidates=%d" %
          (len(session_paths), len(all_obs), len(clusters), emitted), file=sys.stderr)
PY

exit 0
