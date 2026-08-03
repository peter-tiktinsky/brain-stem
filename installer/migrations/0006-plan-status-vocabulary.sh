#!/bin/bash
# migration: 0006-plan-status-vocabulary
# min_from: v0.0.0
# applies_at: v1.13.0
#
# Converge every plan manifest in the adopter's plans corpus to the canonical
# 6-state plan-status vocabulary. The status model collapsed the retired tokens
# verified/closed/archived into the single terminal done-state `completed`. A
# corpus authored before that collapse still carries the retired tokens, which
# the 6-state schema rejects at upgrade: a master read-replica carrying a retired
# token in its sub_plans[] status mirror is refused by the sub-plan aggregator,
# and a plan whose OWN status is retired is orphan-flagged as schema-invalid.
# This migration maps the retired tokens forward so a legacy corpus validates
# under the tightened schema:
#   (a) each depth-1 and depth-2 manifest's OWN `status`:
#       verified | closed | archived  ->  completed
#   (b) the same token map IN-PLACE inside each master's sub_plans[] status
#       mirror, PRESERVING every element's graduation_timestamp, element order,
#       and all other fields byte-for-byte.
# It writes NO timestamps — an in-place token map, never an aggregator re-derive
# (a re-derive would stamp a fresh graduation time onto historical graduations).
#
# Recoverability (the corpus mutation is OUTSIDE install.sh's rollback envelope — the
# journal is $CLAUDE_HOME-keyed and the plans corpus is not pre-snapshotted): before a
# manifest is mutated its ORIGINAL bytes are copied to a WRITE-ONCE per-file pre-image
# sidecar `manifest.json.pre-0006` (guarded if-not-exists, so a converged re-run adds
# none and never clobbers the first pre-image). Recovery: restore a manifest from its
# `.pre-0006` sidecar, OR simply re-run the upgrade — the token map is convergent.
# Cleanup: the `.pre-0006` sidecars are recovery artifacts, safe to delete once the
# upgrade is verified.
#
# Root resolution: MIGRATION_PLANS_ROOT (test seam) -> PLANS_DIR_DEAD (dead-root
# redirect) -> PLANS_DIR -> $HOME/.claude-plans. An absent or empty corpus is a
# no-op (rc 0 — the oldest/empty precondition). A per-file atomic temp+rename
# preserves each file's mode. Convergent + idempotent: after the map every token
# is 6-state, so a re-run finds nothing to change and no manifest is rewritten.
#
# FAIL-CLOSED on missing tooling: python3 is required to rewrite the manifests
# safely; if it is absent this migration exits rc 1 with a remediation message so
# run-migrations halts the chain and the foundation_version is not bumped — a
# silent no-op would leave a legacy corpus rejected by the tightened schema.
#
# bash-3.2 clean; set -u.
set -u

# --- tooling gate: FAIL-CLOSED on missing python3 ---------------------------
if ! command -v python3 >/dev/null 2>&1; then
  printf '0006: python3 not on PATH — cannot converge the plan-status vocabulary safely; FAIL-CLOSED (rc 1). Remediation: install python3 (>=3.6) and re-run the upgrade so the migration chain can complete.\n' >&2
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
  printf '0006: plans root absent (%s) — no-op (nothing to migrate)\n' "${PLANS_ROOT:-<unset>}" >&2
  exit 0
fi

# --- walk + in-place token map (data on argv; program on stdin) -------------
python3 - "$PLANS_ROOT" <<'PY'
import json, os, sys, tempfile

plans_root = sys.argv[1]
RETIRED = {"verified", "closed", "archived"}
TARGET = "completed"

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
    sys.stderr.write("0006: no plan manifests under %s — no-op (empty corpus)\n" % plans_root)
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
    # (a) the plan's OWN status token map.
    own = m.get("status")
    if isinstance(own, str) and own in RETIRED:
        m["status"] = TARGET
        dirty = True
    # (b) in-place token map inside the sub_plans[] status mirror — ONLY the
    # .status value is touched; graduation_timestamp, element order, and every
    # other field are left exactly as-is (no re-derive, no timestamp write).
    subs = m.get("sub_plans")
    if isinstance(subs, list):
        for el in subs:
            if isinstance(el, dict):
                st = el.get("status")
                if isinstance(st, str) and st in RETIRED:
                    el["status"] = TARGET
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
        # <manifest>.pre-0006 snapshot is the local recovery path. Guarded if-not-exists,
        # so a converged (or interrupted) re-run never overwrites the first pre-image.
        # Byte-exact (the original bytes, atomic temp+rename).
        sidecar = mp + ".pre-0006"
        if not os.path.exists(sidecar):
            sfd, stmp = tempfile.mkstemp(dir=d, prefix=".pre-0006.", suffix=".tmp")
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

sys.stderr.write("0006: converged %d manifest(s) to the 6-state plan-status vocabulary\n" % changed)
sys.exit(0)
PY
