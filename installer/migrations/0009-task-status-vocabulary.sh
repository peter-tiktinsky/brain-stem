#!/bin/bash
# migration: 0009-task-status-vocabulary
# min_from: v0.0.0
# applies_at: v1.18.0
#
# Converge every plan manifest's TASK ledger (tasks[].status) in the adopter's
# plans corpus onto the canonical task-status vocabulary. That vocabulary has a
# single declared home — the tasks.items.status declared_vocabulary annotation in
# schemas/plan-manifest-schema.json: the canonical roster is
# not-started / in-progress / blocked / done / cut, with the terminal split
# done + cut. A corpus authored before that declaration carries eight legacy
# spellings on the task axis, and each shipped reader keys on its own hard-coded
# terminal set — so the same task can read settled to one reader and open to
# another, and the stale/drift detectors, the situating card and the tasks
# renderer can disagree about whether a plan is finished. This migration maps the
# eight legacy spellings forward so every reader agrees on one split:
#     complete | completed | closed   ->  done
#     pending  | planned              ->  not-started
#     needs-revision                  ->  blocked
#     deferred | retired              ->  cut
#
# TASK AXIS ONLY. This migration reads and writes tasks[].status and nothing
# else. The PLAN-status axis — a manifest's own status field and the sub_plans[]
# status mirror — is a different vocabulary with a different terminal token, and
# is owned by 0006-plan-status-vocabulary.sh. A manifest whose own status (or
# whose sub_plans[] mirror) carries one of the spellings above is left
# byte-identical on those fields.
#
# MAP-KNOWN-LEAVE-REST, never abort. Only the eight legacy spellings above are
# mapped, matched as the exact bare token. Every other value is left
# byte-unchanged and the migration keeps going: a canonical value, an absent /
# empty / null status, and the free-form settled dispositions a real corpus
# legitimately carries. This mirrors the schema's declared posture — an
# out-of-vocabulary value is FLAGGED by vocabulary-keyed consumers, never refused
# — and an allowlist that aborted on an unrecognized value would refuse
# legitimate settled history.
#
# Recoverability (the corpus mutation is OUTSIDE install.sh's rollback envelope — the
# journal is $CLAUDE_HOME-keyed and the plans corpus is not pre-snapshotted): before a
# manifest is mutated its ORIGINAL bytes are copied to a WRITE-ONCE per-file pre-image
# sidecar `manifest.json.pre-0009` (guarded if-not-exists, so a converged re-run adds
# none and never clobbers the first pre-image). Recovery: restore a manifest from its
# `.pre-0009` sidecar, OR simply re-run the upgrade — the token map is convergent.
# Cleanup: the `.pre-0009` sidecars are recovery artifacts, safe to delete once the
# upgrade is verified.
#
# Root resolution: MIGRATION_PLANS_ROOT (test seam) -> PLANS_DIR_DEAD (dead-root
# redirect) -> PLANS_DIR -> $HOME/.claude-plans. An absent or empty corpus is a
# no-op (rc 0 — the oldest/empty precondition). A per-file atomic temp+rename
# preserves each file's mode. Convergent + idempotent: after the map every mapped
# token is canonical, so a re-run finds nothing to change and no manifest is
# rewritten.
#
# FAIL-CLOSED on missing tooling: python3 is required to rewrite the manifests
# safely; if it is absent this migration exits rc 1 with a remediation message so
# run-migrations halts the chain and the foundation_version is not bumped — a
# silent no-op would leave the readers disagreeing about the same corpus. That is
# the ONLY abort path in this migration.
#
# bash-3.2 clean; set -u.
set -u

# --- tooling gate: FAIL-CLOSED on missing python3 ---------------------------
if ! command -v python3 >/dev/null 2>&1; then
  printf '0009: python3 not on PATH — cannot converge the task-status ledger safely; FAIL-CLOSED (rc 1). Remediation: install python3 (>=3.6) and re-run the upgrade so the migration chain can complete.\n' >&2
  exit 1
fi

# --- root resolution --------------------------------------------------------
if [ -n "${MIGRATION_PLANS_ROOT:-}" ]; then
  PLANS_ROOT="$MIGRATION_PLANS_ROOT"
elif [ -n "${PLANS_DIR_DEAD:-}" ]; then
  PLANS_ROOT="$PLANS_DIR_DEAD"
elif [ -n "${PLANS_DIR:-}" ]; then
  PLANS_ROOT="$PLANS_DIR"
else
  PLANS_ROOT="$HOME/.claude-plans"
fi
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

# --- oldest/empty precondition: absent plans root -> no-op ------------------
if [ -z "$PLANS_ROOT" ] || [ ! -d "$PLANS_ROOT" ]; then
  printf '0009: plans root absent (%s) — no-op (nothing to migrate)\n' "${PLANS_ROOT:-<unset>}" >&2
  exit 0
fi

# --- walk + in-place token map (data on argv; program on stdin) -------------
python3 - "$PLANS_ROOT" <<'PY'
import json, os, sys, tempfile

plans_root = sys.argv[1]

# The canonical task-status targets, each bound on its own line; the legacy map
# below then carries one legacy spelling per line (a single vocabulary token per
# physical line).
CANON_DONE = "done"
CANON_NOT_STARTED = "not-started"
CANON_BLOCKED = "blocked"
CANON_CUT = "cut"

# The eight legacy task-status spellings, mapped forward to the canonical roster.
LEGACY_TASK_STATUS = {
    "complete": CANON_DONE,
    "completed": CANON_DONE,
    "closed": CANON_DONE,
    "pending": CANON_NOT_STARTED,
    "planned": CANON_NOT_STARTED,
    "needs-revision": CANON_BLOCKED,
    "deferred": CANON_CUT,
    "retired": CANON_CUT,
}

def is_plan_dir(name):
    return not (name.startswith(".") or name.startswith("_") or name == "Logs")

# Collect candidate manifest paths at depth 1 and depth 2 (the scaffolder layout).
manifests = []
try:
    for e1 in sorted(os.listdir(plans_root)):
        d1 = os.path.join(plans_root, e1)
        if not os.path.isdir(d1) or not is_plan_dir(e1):
            continue
        mp1 = os.path.join(d1, "manifest.json")
        if os.path.isfile(mp1):
            manifests.append(mp1)
        for e2 in sorted(os.listdir(d1)):
            d2 = os.path.join(d1, e2)
            if not os.path.isdir(d2) or not is_plan_dir(e2):
                continue
            mp2 = os.path.join(d2, "manifest.json")
            if os.path.isfile(mp2):
                manifests.append(mp2)
except OSError:
    pass

if not manifests:
    sys.stderr.write("0009: no plan manifests under %s — no-op (empty corpus)\n" % plans_root)
    sys.exit(0)

changed = 0
for mp in manifests:
    try:
        with open(mp, "rb") as fh:
            raw_bytes = fh.read()
        m = json.loads(raw_bytes.decode("utf-8"))
    except (OSError, ValueError):
        continue
    if not isinstance(m, dict):
        continue
    dirty = False
    # TASK AXIS ONLY: the tasks[] ledger's status values. The manifest's own
    # status and its sub_plans[] status mirror are the PLAN axis (owned by
    # 0006) and are neither read nor written here.
    tasks = m.get("tasks")
    if isinstance(tasks, list):
        for t in tasks:
            if not isinstance(t, dict):
                continue
            st = t.get("status")
            # MAP-KNOWN-LEAVE-REST: only an exact bare legacy token maps. Any
            # other value — a canonical one, an absent/empty/null status, or a
            # free-form settled disposition — falls through byte-unchanged, and
            # the walk continues (there is no abort-on-unrecognized path).
            if isinstance(st, str) and st in LEGACY_TASK_STATUS:
                t["status"] = LEGACY_TASK_STATUS[st]
                dirty = True
    if not dirty:
        continue
    # Atomic per-file temp+rename, preserving the original file mode (the
    # temp+mv mode-loss trap).
    d = os.path.dirname(mp) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".manifest.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(m, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        try:
            os.chmod(tmp, os.stat(mp).st_mode)
        except OSError:
            pass
        # Write-once pre-image sidecar (recovery point) BEFORE the mutation lands: this
        # corpus mutation is outside install.sh's rollback envelope, so the per-file
        # <manifest>.pre-0009 snapshot is the local recovery path. Guarded if-not-exists,
        # so a converged (or interrupted) re-run never overwrites the first pre-image.
        # Byte-exact (the original bytes, atomic temp+rename).
        sidecar = mp + ".pre-0009"
        if not os.path.exists(sidecar):
            sfd, stmp = tempfile.mkstemp(dir=d, prefix=".pre-0009.", suffix=".tmp")
            try:
                with os.fdopen(sfd, "wb") as sfh:
                    sfh.write(raw_bytes)
                os.replace(stmp, sidecar)
            except Exception:
                if os.path.exists(stmp):
                    os.unlink(stmp)
                raise
        os.replace(tmp, mp)
        changed += 1
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

sys.stderr.write("0009: converged the task ledger in %d manifest(s) to the canonical task-status vocabulary\n" % changed)
sys.exit(0)
PY
