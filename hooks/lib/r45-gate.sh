#!/bin/bash
# r45-gate.sh — evaluate the R-45 deny-default promotion trigger over the memory-schema trail.
#
# USAGE
#   r45-gate.sh [--trail <path>] [--labels <path>] [--since <ISO-8601>]
#   r45-gate.sh --label [--list | --answers <TP|FP|skip,...>]
#   r45-gate.sh --self-test
#
# DEFAULTS. The trail is the audit file hooks/pre-write-guard.sh appends to,
# $HOOKS_STATE/memory-schema-advisory-history.jsonl. The labels file is
# $HOOKS_STATE/memory-schema-gate-labels.tsv. HOOKS_STATE resolves through the sibling
# paths.sh, as the hook resolves it. With no --since there is no time filter; a --since is
# honored as given.
#
# TRIGGER. GATE MET iff, after filtering, the trail holds >= 10 rows with `"would_deny": true`
# AND every counted row carries an operator label AND the false-positive share of the counted
# rows is < 15%. Filters, in order:
#   - rows with no `would_deny` verdict are skipped: only a row the hook marked would-deny is
#     a candidate;
#   - rows whose `ts` is before --since, when --since is given;
#   - rows whose file basename is allowlisted (`MEMORY*.md`, `episodic-chronicle*.md`);
#   - rows carrying `"override": true` (a write made with MEMORY_SCHEMA_OK=1 is an
#     operator-sanctioned out-of-triad write, not a model mistake: it is out of both the count
#     and the false-positive denominator).
# The gate never re-derives authorship: the hook computed `would_deny` with the model-authored
# clause, so the gate only filters and counts.
#
# LABELS TSV. One row per counted trail row: `<ts>\t<file>\t<TP|FP>`, keyed on the row's exact
# `ts` and `file` values. Blank lines and lines starting with `#` are ignored. An absent labels
# file means no row is labelled; an absent trail is zero rows.
#
# LABELLING. `--label --list` prints the counted rows that carry no label, one
# `<n>\t<ts>\t<file>\t<missing>` line each (the missing fields joined by `; `, `-` when none),
# deduplicated on the (ts, file) key in first-seen trail order, then one footer line
# `<N> row(s) to label; labels file: <path>`. A row whose ts or file holds a tab, CR or LF
# cannot be keyed in the TSV and is left out of the list; the evaluation keeps counting it
# unlabelled. `--label --answers <TP|FP|skip,...>` applies the verdicts to those rows in
# order, matched case-insensitively: each non-skip row is appended to the labels file as
# `<ts>\t<file>\t<TP|FP>` and existing bytes are never rewritten; `skip` leaves the row
# unlabelled. The whole answer list is validated before any write, and an unwritable labels
# file is refused before the first byte is written. `--label` alone prompts per row on
# stderr (`TP, FP, skip or quit? `), reads one answer line from stdin — end of input, or a
# closed stdin, ends like quit — and appends each answer at once, so an interrupt keeps
# every answer already given. `--trail`, `--labels` and `--since` apply to the label modes
# exactly as they do to an evaluation.
#
# OUTPUT. One line, `GATE MET: ...` or `GATE NOT MET: ...`, with the counts and `since=none`
# when no --since is given. Exit 0 MET, 1 NOT MET, 2 for a usage error, an unparseable
# --since, or a trail or labels path that exists but cannot be read. A NOT MET verdict with
# unlabelled rows ends the line with `(label them: r45-gate.sh --label)`; every other
# verdict line carries no hint. An evaluation
# writes nothing; only --label writes, and it only appends rows to the labels file;
# nothing ever writes the trail.
#
# Bash 3.2 clean per R-23. Argv-based Python per R-24.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/paths.sh" 2>/dev/null || true
set -u

USAGE="usage: r45-gate.sh [--trail <path>] [--labels <path>] [--since <ISO-8601>] [--label [--list | --answers <TP|FP|skip,...>]] | --self-test"

# The helpers below read self_test's locals (dir, self, pass, fail, rc) by bash dynamic scope;
# they are top-level definitions, each closing brace at column 0.
# mk <name> <spec...>: each spec is `ts|file|would_deny|override|label` (label TP, FP or -).
mk() {
  local name="$1" spec ts file wd ov lab; shift
  : > "$dir/$name.jsonl"; : > "$dir/$name.tsv"
  for spec in "$@"; do
    IFS='|' read -r ts file wd ov lab <<EOF
$spec
EOF
    printf '{"ts": "%s", "tool": "Write", "file": "%s", "missing_fields": ["type: invalid value"], "type_source": "top", "would_deny": %s, "phase": "1-advisory", "override": %s}\n' \
      "$ts" "$file" "$wd" "$ov" >> "$dir/$name.jsonl"
    [ "$lab" != "-" ] && printf '%s\t%s\t%s\n' "$ts" "$file" "$lab" >> "$dir/$name.tsv"
  done
  return 0
}
rowset() {  # rowset <n> <label> [override] [file-prefix] [date] -> n spec lines
  local n="$1" lab="$2" ov="${3:-false}" pre="${4:-m}" day="${5:-2020-06-10}" i=1
  while [ "$i" -le "$n" ]; do
    printf '%sT12:00:%02dZ|/h/.claude/projects/p/memory/%s_%d.md|true|%s|%s\n' "$day" "$i" "$pre" "$i" "$ov" "$lab"
    i=$((i + 1))
  done
}
# check <name> <expect MET|NOT MET> <expect counted> [extra args]: run with the case's files
check() {
  local name="$1" want="$2" wantn="$3" before after out; shift 3
  before="$(shasum -a 256 "$dir/$name.jsonl" | cut -d' ' -f1)"
  out="$(bash "$self" --trail "$dir/$name.jsonl" --labels "$dir/$name.tsv" "$@")"
  after="$(shasum -a 256 "$dir/$name.jsonl" | cut -d' ' -f1)"
  case "$out" in
    "GATE $want:"*) : ;;
    *) echo "  FAIL: $name: expected GATE $want, got: $out"; fail=$((fail + 1)); return ;;
  esac
  if ! printf '%s' "$out" | grep -q " counted=$wantn "; then
    echo "  FAIL: $name: expected counted=$wantn, got: $out"; fail=$((fail + 1)); return
  fi
  if [ "$before" != "$after" ]; then
    echo "  FAIL: $name: the trail changed during evaluation"; fail=$((fail + 1)); return
  fi
  echo "  PASS: $name -> $out"; pass=$((pass + 1))
}
# expect_rc <label> <want rc> <args...>
expect_rc() {
  local label="$1" want="$2" out; shift 2
  out="$(bash "$self" "$@" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq "$want" ] && ! printf '%s' "$out" | grep -q '^GATE '; then
    echo "  PASS: $label exits $want"; pass=$((pass + 1))
  else
    echo "  FAIL: $label exited $rc (want $want)"; fail=$((fail + 1))
  fi
}

self_test() {
  local dir self rc pass=0 fail=0
  self="${BASH_SOURCE[0]}"
  dir="$(mktemp -d)" || { echo "self-test: mktemp failed" >&2; return 2; }
  trap 'rm -rf "$dir"' RETURN


  # The seed dates and file names below are synthetic fixture data, not provenance.
  local IFS_NL='
'
  # shellcheck disable=SC2046
  local OLDIFS="$IFS"; IFS="$IFS_NL"
  mk nine_tp           $(rowset 9 TP)
  mk ten_tp            $(rowset 10 TP)
  mk ten_two_fp        $(rowset 8 TP) $(rowset 2 FP false f)
  mk allowlisted       $(rowset 9 TP) \
                       "2020-06-10T13:00:01Z|/h/.claude/projects/p/memory/MEMORY.old.md|true|false|TP" \
                       "2020-06-10T13:00:02Z|/h/.claude/projects/p/memory/MEMORY.md|true|false|TP" \
                       "2020-06-10T13:00:03Z|/h/.claude/projects/p/memory/episodic-chronicle.md|true|false|TP"
  mk before_since      $(rowset 9 TP) $(rowset 3 TP false old 2000-01-01)
  mk not_would_deny    $(rowset 9 TP) \
                       "2020-06-11T12:00:01Z|/h/.claude/projects/p/memory/x_1.md|false|false|TP" \
                       "2020-06-11T12:00:02Z|/h/.claude/projects/p/memory/x_2.md|false|false|TP"
  mk unlabelled        $(rowset 9 TP) $(rowset 1 - false u)
  mk hatch_ten         $(rowset 9 TP) $(rowset 1 TP true h)
  mk hatch_eleven      $(rowset 10 TP) $(rowset 1 FP true h)
  IFS="$OLDIFS"

  local S="--since 2010-01-01T00:00:00Z"
  echo "=== r45-gate.sh --self-test ==="
  # shellcheck disable=SC2086
  {
    check nine_tp        "NOT MET" 9  $S
    check ten_tp         "MET"     10 $S
    check ten_two_fp     "NOT MET" 10 $S
    check allowlisted    "NOT MET" 9  $S
    check before_since   "NOT MET" 9  $S
    check not_would_deny "NOT MET" 9  $S
    check unlabelled     "NOT MET" 10 $S
    check hatch_ten      "NOT MET" 9  $S
    check hatch_eleven   "MET"     10 $S
  }
  # With no --since there is no time filter: the three old rows count too.
  cp "$dir/before_since.jsonl" "$dir/no_since.jsonl"; cp "$dir/before_since.tsv" "$dir/no_since.tsv"
  check no_since "MET" 12
  expect_rc "an unknown flag" 2 --bogus
  expect_rc "an unparseable --since" 2 --trail "$dir/ten_tp.jsonl" --labels "$dir/ten_tp.tsv" --since not-a-date

  echo "r45-gate self-test: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

TRAIL=""; LABELS=""; SINCE=""; SELF_TEST=0; LABEL=0; LIST=0; ANSWERS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --label) LABEL=1; shift ;;
    --list) LIST=1; shift ;;
    --trail|--labels|--since|--answers)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "r45-gate: $1 needs a value" >&2; echo "$USAGE" >&2; exit 2; fi
      case "$1" in --trail) TRAIL="$2" ;; --labels) LABELS="$2" ;; --since) SINCE="$2" ;; --answers) ANSWERS="$2" ;; esac
      shift 2 ;;
    *) echo "r45-gate: unknown argument '$1'" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done

if [ "$LIST" -eq 1 ] && [ -n "$ANSWERS" ]; then
  echo "r45-gate: --list and --answers cannot be combined" >&2; exit 2
fi
if [ "$LIST" -eq 1 ] || [ -n "$ANSWERS" ]; then
  [ "$LABEL" -eq 1 ] || { echo "r45-gate: --list and --answers need --label" >&2; exit 2; }
fi

if [ "$SELF_TEST" -eq 1 ]; then
  if [ -n "$TRAIL$LABELS$SINCE" ]; then echo "$USAGE" >&2; exit 2; fi
  if [ "$LABEL" -eq 1 ] || [ "$LIST" -eq 1 ] || [ -n "$ANSWERS" ]; then echo "$USAGE" >&2; exit 2; fi
  self_test
  exit $?
fi

if [ -z "$TRAIL" ] || [ -z "$LABELS" ]; then
  STATE="${HOOKS_STATE:-}"
  if [ -z "$STATE" ]; then
    echo "r45-gate: HOOKS_STATE did not resolve (paths.sh not found beside this script); pass --trail and --labels" >&2
    exit 2
  fi
  [ -n "$TRAIL" ] || TRAIL="$STATE/memory-schema-advisory-history.jsonl"
  [ -n "$LABELS" ] || LABELS="$STATE/memory-schema-gate-labels.tsv"
fi

MODE="eval"
[ "$LABEL" -eq 1 ] && MODE="list"

GATE_OUT="$(python3 - "$TRAIL" "$SINCE" "$LABELS" "$MODE" <<'PY'
import datetime, fnmatch, json, os, sys

trail, since_raw, labels_path, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def parse_ts(raw):
    s = raw.strip()
    if s.endswith('Z'):
        s = s[:-1] + '+00:00'
    d = datetime.datetime.fromisoformat(s)
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d

def read_input(path):
    """Return the file's lines, or None when the path is absent. A path that exists but is not
    a readable regular file is a hard error (exit 2), never an empty input."""
    if not os.path.exists(path):
        return None
    if not os.path.isfile(path):
        sys.stderr.write('r45-gate: not a readable file: %s\n' % path)
        sys.exit(2)
    try:
        with open(path) as f:
            return f.readlines()
    except OSError as exc:
        sys.stderr.write('r45-gate: cannot read %s (%s)\n' % (path, exc))
        sys.exit(2)

def fmt_missing(row):
    """Render a counted row's missing_fields for the labelling list: items joined by
    '; ', '-' when the key is absent or empty; a tab, CR or LF inside the text prints
    as a space; a non-list value is coerced through str()."""
    mf = row.get('missing_fields')
    if isinstance(mf, list):
        items = [str(i) for i in mf]
    elif mf is None:
        items = []
    else:
        items = [str(mf)]
    text = '; '.join(items).replace('\t', ' ').replace('\r', ' ').replace('\n', ' ')
    return text if text else '-'

since = None
if since_raw:
    try:
        since = parse_ts(since_raw)
    except ValueError:
        sys.stderr.write('r45-gate: --since is not an ISO-8601 timestamp: %s\n' % since_raw)
        sys.exit(2)

label_lines = read_input(labels_path)
trail_lines = read_input(trail)

labels = {}
labels_state = 'present' if label_lines is not None else 'absent'
for line in label_lines or []:
    line = line.rstrip('\n')
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    parts = line.split('\t')
    if len(parts) == 3 and parts[2].strip() in ('TP', 'FP'):
        labels[(parts[0], parts[1])] = parts[2].strip()

ALLOW = ('MEMORY*.md', 'episodic-chronicle*.md')
counted = tp = fp = unlabelled = unparsed = excluded_since = excluded_allow = excluded_override = 0
listed = []          # unlabelled counted (ts, file, row), deduplicated, first-seen order
seen_keys = set()
trail_state = 'present' if trail_lines is not None else 'absent'
for line in trail_lines or []:
    if not line.strip():
        continue
    try:
        row = json.loads(line)
        ts = parse_ts(str(row.get('ts', '')))
    except (ValueError, TypeError, AttributeError):
        unparsed += 1
        continue
    if row.get('would_deny') is not True:
        continue
    if since is not None and ts < since:
        excluded_since += 1
        continue
    base = os.path.basename(str(row.get('file', '')))
    if any(fnmatch.fnmatchcase(base, p) for p in ALLOW):
        excluded_allow += 1
        continue
    if row.get('override') is True:
        excluded_override += 1
        continue
    counted += 1
    lab = labels.get((str(row.get('ts', '')), str(row.get('file', ''))))
    if lab == 'TP':
        tp += 1
    elif lab == 'FP':
        fp += 1
    else:
        unlabelled += 1
        if mode == 'list':
            key = (str(row.get('ts', '')), str(row.get('file', '')))
            if key not in seen_keys:
                seen_keys.add(key)
                if not any(c in key[0] or c in key[1] for c in '\t\r\n'):
                    listed.append((key[0], key[1], row))

rate = (100.0 * fp / counted) if counted else 0.0
met = counted >= 10 and unlabelled == 0 and fp * 100 < 15 * counted
if mode == 'list':
    # One field per line (ts, file, missing): a per-line read cannot collapse an
    # empty file field the way a tab split would, and no field can hold a newline.
    for ts_raw, file_raw, row in listed:
        sys.stdout.write('%s\n%s\n%s\n' % (ts_raw, file_raw, fmt_missing(row)))
    sys.exit(0)
print('GATE %s: counted=%d tp=%d fp=%d unlabelled=%d fp_rate=%.1f%% excluded(since=%d allowlist=%d override=%d) unparsed=%d trail=%s labels=%s since=%s%s'
      % ('MET' if met else 'NOT MET', counted, tp, fp, unlabelled, rate,
         excluded_since, excluded_allow, excluded_override, unparsed, trail_state, labels_state,
         since_raw if since is not None else 'none',
         '' if met or unlabelled == 0 else ' (label them: r45-gate.sh --label)'))
sys.exit(0 if met else 1)
PY
)"
GATE_RC=$?

if [ "$MODE" = "list" ]; then
  [ "$GATE_RC" -eq 0 ] || exit "$GATE_RC"
  # The python core's row stream: one field per line (ts, file, missing), read
  # back one field at a time so an empty file field cannot collapse.
  ROW_TS=(); ROW_FILE=(); ROW_MISS=()
  while IFS= read -r rowf1 && IFS= read -r rowf2 && IFS= read -r rowf3; do
    ROW_TS+=("$rowf1"); ROW_FILE+=("$rowf2"); ROW_MISS+=("$rowf3")
  done <<EOF_ROWS
$GATE_OUT
EOF_ROWS
  N=${#ROW_TS[@]}
  upper_answer() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
  # Writability pre-check: on the labels file when it exists, otherwise on its
  # parent directory. A labels path that is not a regular file never reaches it.
  labels_writable() {
    if [ -e "$LABELS" ]; then
      [ -f "$LABELS" ] && [ -w "$LABELS" ]
    else
      LDIR="$(dirname "$LABELS")"
      [ -d "$LDIR" ] && [ -w "$LDIR" ]
    fi
  }
  # append_label <row index> <VERDICT>: append one TSV row. A non-empty labels
  # file with no trailing newline gets one before the first appended row only,
  # so the pre-existing last line stays intact and an all-skip run writes
  # nothing at all.
  NL_FIXED=0
  append_label() {
    if [ "$NL_FIXED" -eq 0 ]; then
      if [ -s "$LABELS" ] && [ "$(tail -c 1 "$LABELS" | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
        printf '\n' >> "$LABELS"
      fi
      NL_FIXED=1
    fi
    printf '%s\t%s\t%s\n' "${ROW_TS[$1]}" "${ROW_FILE[$1]}" "$2" >> "$LABELS"
  }

  if [ "$LIST" -eq 1 ]; then
    i=1
    while [ "$i" -le "$N" ]; do
      printf '%d\t%s\t%s\t%s\n' "$i" "${ROW_TS[$((i - 1))]}" "${ROW_FILE[$((i - 1))]}" "${ROW_MISS[$((i - 1))]}"
      i=$((i + 1))
    done
    printf '%d row(s) to label; labels file: %s\n' "$N" "$LABELS"
    exit 0
  fi

  if [ -n "$ANSWERS" ]; then
    # --label --answers <a,b,...>: the whole list is validated before any write.
    IFS=',' read -r -a TOKENS <<<"$ANSWERS"
    K=${#TOKENS[@]}
    i=0
    while [ "$i" -lt "$K" ]; do
      case "$(upper_answer "${TOKENS[$i]}")" in
        TP|FP|SKIP) ;;
        *) echo "r45-gate: --answers: '${TOKENS[$i]}' is not TP, FP or skip" >&2; exit 2 ;;
      esac
      i=$((i + 1))
    done
    if [ "$K" -gt "$N" ]; then
      echo "r45-gate: --answers gives $K answers for $N row(s)" >&2; exit 2
    fi
    APPEND=0
    i=0
    while [ "$i" -lt "$K" ]; do
      case "$(upper_answer "${TOKENS[$i]}")" in TP|FP) APPEND=1 ;; esac
      i=$((i + 1))
    done
    if [ "$APPEND" -eq 1 ]; then
      labels_writable || { echo "r45-gate: cannot write $LABELS" >&2; exit 2; }
    fi
    RECORDED=0
    i=0
    while [ "$i" -lt "$K" ]; do
      VERDICT="$(upper_answer "${TOKENS[$i]}")"
      if [ "$VERDICT" = "SKIP" ]; then
        printf 'skipped: %s (%s)\n' "${ROW_FILE[$i]}" "${ROW_TS[$i]}"
      else
        append_label "$i" "$VERDICT"
        printf 'labelled %s: %s (%s)\n' "$VERDICT" "${ROW_FILE[$i]}" "${ROW_TS[$i]}"
        RECORDED=$((RECORDED + 1))
      fi
      i=$((i + 1))
    done
    printf 'recorded %d label(s) in %s\n' "$RECORDED" "$LABELS"
    exit 0
  fi

  # --label alone: the interactive prompt over the same rows. Prompts go to
  # stderr; each answer is appended at once, so an interrupt keeps every answer
  # already given; end of input, or a closed stdin, ends like quit.
  printf '%d row(s) to label; labels file: %s\n' "$N" "$LABELS"
  if [ "$N" -ge 1 ]; then
    labels_writable || { echo "r45-gate: cannot write $LABELS" >&2; exit 2; }
  fi
  RECORDED=0
  i=0
  while [ "$i" -lt "$N" ]; do
    printf '[%d/%d] %s\n' $((i + 1)) "$N" "${ROW_FILE[$i]}"
    printf '  ts: %s\n' "${ROW_TS[$i]}"
    printf '  missing: %s\n' "${ROW_MISS[$i]}"
    while :; do
      printf 'TP, FP, skip or quit? ' >&2
      if read -r ans 2>/dev/null; then :; else ans="quit"; fi
      case "$(upper_answer "$ans")" in
        TP|FP)
          append_label "$i" "$(upper_answer "$ans")"
          printf 'labelled %s: %s (%s)\n' "$(upper_answer "$ans")" "${ROW_FILE[$i]}" "${ROW_TS[$i]}"
          RECORDED=$((RECORDED + 1))
          break ;;
        S|SKIP)
          printf 'skipped: %s (%s)\n' "${ROW_FILE[$i]}" "${ROW_TS[$i]}"
          break ;;
        Q|QUIT)
          i="$N"
          break ;;
        *)
          printf 'answer TP, FP, skip or quit\n' >&2 ;;
      esac
    done
    i=$((i + 1))
  done
  printf 'recorded %d label(s) in %s\n' "$RECORDED" "$LABELS"
  exit 0
fi

[ -z "$GATE_OUT" ] || printf '%s\n' "$GATE_OUT"
exit "$GATE_RC"
