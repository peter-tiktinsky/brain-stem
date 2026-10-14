#!/usr/bin/env bash
# skills/govern/lib/assemble-validated.sh — compose validated.json from a
# propose-step proposal and the operator's per-field rulings.
#
# Reached through `process.sh assemble` (the verb arm exec's this script, so a
# signal sent to the invoking pid reaches this script's own trap) or run directly:
#
#   assemble-validated.sh <kind> --proposal <proposal.json> --rulings <rulings.json> [--out <validated.json>]
#
# The rulings file is {"rulings": [...]}. Each ruling is one of
#   {"target": T, "verdict": "accept"}
#   {"target": T, "verdict": "edit", "value": <json>}
#   {"target": T, "verdict": "reject", "reason": "<text>"}
# A field with no ruling is accepted as proposed. The result is the proposal with
# every edit set at its target, every rejected field removed (a pillar a reject
# emptied is dropped) and a top-level rejected_fields object appended last.
#
# Every refusal exits 2, prints one `govern-assemble: refused: <text>` line on
# stderr and writes nothing. A missing jq exits 3. A failed write exits 6.
# With --out the result goes to a temp file beside the target and is renamed
# into place; a trap removes the temp file on every exit, a signal included.
# Both inputs reach jq through --slurpfile; no data crosses a command substitution.
#
# bash 3.2 compatible.

set -u

USAGE_LINE='usage: process.sh assemble <kind> --proposal <proposal.json> --rulings <rulings.json> [--out <validated.json>]'

TMPD=""
OUT_TMP=""
cleanup() {
  if [ -n "$OUT_TMP" ]; then rm -f "$OUT_TMP"; fi
  if [ -n "$TMPD" ]; then rm -rf "$TMPD"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

refuse() {
  printf 'govern-assemble: refused: %s\n' "$1" >&2
  exit 2
}

usage() {
  printf '%s\n' "$USAGE_LINE"
  printf '%s\n' \
    '' \
    'Compose validated.json from a proposal (process.sh propose) and the' \
    'operator'"'"'s per-field rulings. Kinds: folder, file-type, tag-extension,' \
    'writer, doc-amender-prompt. The kind may also be given as --kind <kind>.' \
    '' \
    'Rulings file: {"rulings": [...]}, each ruling one of' \
    '  {"target": T, "verdict": "accept"}' \
    '  {"target": T, "verdict": "edit", "value": <json>}' \
    '  {"target": T, "verdict": "reject", "reason": "<text>"}' \
    '' \
    'Targets: writer_reference.frontmatter.<field>, prompt_asset.frontmatter.<field>,' \
    'fan_in.<field>, prompt_asset.body, <pillar>.<field>. A field with no ruling' \
    'is accepted as proposed. Without --out the validated JSON goes to stdout.' \
    '' \
    'Exit: 0 ok, 2 refused (nothing written), 3 jq missing, 6 write failed.'
}

# ---- arguments (left to right; the first failing check speaks) ----------------
KIND=""
KIND_SET=0
PROPOSAL=""
RULINGS=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --proposal)
      v="${2-}"
      [ -n "$v" ] || refuse "--proposal requires a non-empty path"
      PROPOSAL="$v"
      shift 2
      ;;
    --rulings)
      v="${2-}"
      [ -n "$v" ] || refuse "--rulings requires a non-empty path"
      RULINGS="$v"
      shift 2
      ;;
    --out)
      v="${2-}"
      [ -n "$v" ] || refuse "--out requires a non-empty path"
      OUT="$v"
      shift 2
      ;;
    --kind)
      v="${2-}"
      [ -n "$v" ] || refuse "--kind requires a value"
      [ "$KIND_SET" = 0 ] || refuse "kind given twice"
      KIND="$v"
      KIND_SET=1
      shift 2
      ;;
    -*)
      refuse "unknown argument: $1"
      ;;
    *)
      if [ "$KIND_SET" = 0 ]; then
        KIND="$1"
        KIND_SET=1
        shift
      else
        refuse "unknown argument: $1"
      fi
      ;;
  esac
done

[ -n "$KIND" ] || refuse "a kind is required"
case "$KIND" in
  folder|file-type|tag-extension|writer|doc-amender-prompt)
    ;;
  project)
    refuse "kind 'project' is committed as proposed; it has no per-field rulings"
    ;;
  *)
    refuse "unknown kind: $KIND"
    ;;
esac
if [ -z "$PROPOSAL" ] || [ -z "$RULINGS" ]; then
  refuse "--proposal and --rulings are both required"
fi

OUT_DIR=""
if [ -n "$OUT" ]; then
  if [ -d "$OUT" ]; then
    refuse "--out is a directory: $OUT"
  fi
  case "$OUT" in
    */*)
      OUT_DIR="${OUT%/*}"
      [ -n "$OUT_DIR" ] || OUT_DIR="/"
      ;;
    *)
      OUT_DIR="."
      ;;
  esac
  [ -d "$OUT_DIR" ] || refuse "--out directory not found: $OUT_DIR"
  if [ ! -w "$OUT_DIR" ] || [ ! -x "$OUT_DIR" ]; then
    refuse "--out directory not writable: $OUT_DIR"
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'govern-assemble: jq is required\n' >&2
  exit 3
fi

# ---- the two inputs ----------------------------------------------------------
if [ ! -f "$PROPOSAL" ] || [ ! -r "$PROPOSAL" ]; then
  refuse "proposal not readable: $PROPOSAL"
fi
if [ ! -f "$RULINGS" ] || [ ! -r "$RULINGS" ]; then
  refuse "rulings not readable: $RULINGS"
fi
if ! jq -s -e 'length == 1' "$PROPOSAL" >/dev/null 2>&1; then
  refuse "proposal is not valid JSON: $PROPOSAL"
fi
if ! jq -s -e 'length == 1' "$RULINGS" >/dev/null 2>&1; then
  refuse "rulings is not valid JSON: $RULINGS"
fi
if ! jq -e 'type == "object"' "$PROPOSAL" >/dev/null 2>&1; then
  refuse "proposal is not a JSON object: $PROPOSAL"
fi

# ---- the jq program: target table, ruling checks, apply ---------------------
# A target is rulable only when it is in the table built from the proposal:
# writer_reference.frontmatter.<field>, prompt_asset.frontmatter.<field>,
# fan_in.<field>, the exact prompt_asset.body, then <pillar>.<field>.
JQ_DEFS='
def isobj: type == "object";
def q: [39] | implode;
def has_el($x): any(.[]; . == $x);
def kindtext: if . == null then "" elif type == "string" then . else tojson end;

def tbl:
  . as $P
  | ( if (($P.writer_reference | isobj) and ($P.writer_reference.frontmatter | isobj))
      then [ $P.writer_reference.frontmatter | keys_unsorted[] as $k
             | {t: ("writer_reference.frontmatter." + $k), path: ["writer_reference", "frontmatter", $k], scope: "writer_reference.frontmatter", field: $k} ]
      else [] end )
  + ( if (($P.prompt_asset | isobj) and ($P.prompt_asset.frontmatter | isobj))
      then [ $P.prompt_asset.frontmatter | keys_unsorted[] as $k
             | {t: ("prompt_asset.frontmatter." + $k), path: ["prompt_asset", "frontmatter", $k], scope: "prompt_asset.frontmatter", field: $k} ]
      else [] end )
  + ( if ($P.fan_in | isobj)
      then [ $P.fan_in | keys_unsorted[] as $k
             | {t: ("fan_in." + $k), path: ["fan_in", $k], scope: "fan_in", field: $k} ]
      else [] end )
  + ( if (($P.prompt_asset | isobj) and ($P.prompt_asset | has("body")))
      then [ {t: "prompt_asset.body", path: ["prompt_asset", "body"], scope: "prompt_asset", field: "body"} ]
      else [] end )
  + ( if (($P.pillars | type) == "array")
      then [ $P.pillars | to_entries[]
             | select((.value | isobj) and ((.value.pillar | type) == "string") and (.value.payload | isobj))
             | .key as $i | .value.pillar as $pn
             | .value.payload | keys_unsorted[] as $k
             | {t: ($pn + "." + $k), path: ["pillars", $i, "payload", $k], scope: $pn, field: $k} ]
      else [] end );

def ruling_err($n; $seen; $tbl):
  . as $r
  | if ((($r | isobj) and (($r.target | type) == "string") and (($r.verdict | type) == "string")) | not)
    then "ruling \($n): must be an object with a string target and a string verdict"
    elif ((["accept", "edit", "reject"] | has_el($r.verdict)) | not)
    then "ruling \($n): unknown verdict \(q)\($r.verdict)\(q)"
    else
      ( {accept: ["target", "verdict"], edit: ["target", "verdict", "value"], reject: ["target", "verdict", "reason"]}[$r.verdict] ) as $allowed
      | ( [ $r | keys_unsorted[] | select(. as $k | (($allowed | has_el($k)) | not)) ] | .[0] ) as $bad
      | if $bad != null then "ruling \($n): unknown key \(q)\($bad)\(q)"
        elif ($r.verdict == "edit" and (($r | has("value")) | not)) then "ruling \($n): edit needs a value"
        elif ($r.verdict == "reject" and ((($r.reason | type) != "string") or (($r.reason | length) == 0))) then "ruling \($n): reject needs a non-empty reason"
        elif (($tbl | map(.t) | has_el($r.target)) | not) then "ruling \($n): no such target \(q)\($r.target)\(q)"
        elif ($seen | has_el($r.target)) then "ruling \($n): target \(q)\($r.target)\(q) is ruled twice"
        else null end
    end;

def ruling_errors($tbl):
  foreach (.rulings | to_entries[]) as $e (
    {seen: [], err: null};
    . as $st
    | ($e.value | ruling_err($e.key + 1; $st.seen; $tbl)) as $err
    | {seen: ($st.seen + [($e.value | if isobj then .target else null end)]), err: $err};
    .err)
  | select(. != null);

def run($rl; $tbl):
  . as $P
  | reduce $rl[] as $x ({doc: $P, rej: {}, idx: []};
      ( [ $tbl[] | select(.t == $x.target) ] | .[0] ) as $e
      | if $x.verdict == "edit" then .doc |= setpath($e.path; $x.value)
        elif $x.verdict == "reject" then
          ( .doc |= delpaths([$e.path]) )
          | ( .rej[$e.scope][$e.field] = $x.reason )
          | ( if $e.path[0] == "pillars" then .idx += [$e.path[1]] else . end )
        else . end )
  | ( [ $rl[] | select(.target == "prompt_asset.frontmatter.amendment_strategy" and .verdict == "edit") ] | .[0] ) as $ae
  | ( $rl | any(.[]; .target == "fan_in.amendment_strategy") ) as $own
  | if (($ae != null) and ($own | not) and ((.doc.fan_in) | isobj))
    then .doc.fan_in.amendment_strategy = $ae.value
    else . end
  | ( .idx | unique ) as $ri
  | . as $S
  | ( [ $ri[] | select(($S.doc.pillars[.].payload) == {}) ] ) as $drop
  | if ($drop | length) > 0
    then .doc.pillars |= [ to_entries[] | select(. as $en | (($drop | has_el($en.key)) | not)) | .value ]
    else . end
  | . as $F
  | { doc: $F.doc, rej: $F.rej,
      nopillar: ((($P.pillars | type) == "array") and (($P.pillars | length) > 0) and (($F.doc.pillars | length) == 0)) };

def final:
  .rej as $J
  | .doc
  | if ($J | length) > 0 then (del(.rejected_fields) + {rejected_fields: $J}) else . end;
'

JQ_CHECK='
$pf[0] as $P
| $rf[0] as $R
| if (($P.kind | kindtext) != $kind) then
    "proposal .kind \(q)\($P.kind | kindtext)\(q) does not match \(q)\($kind)\(q)"
  elif ((($R | isobj) | not) or (($R.rulings | type) != "array")) then
    "rulings must be {\"rulings\": [...]}"
  else
    ($P | tbl) as $T
    | ( [ $R | ruling_errors($T) ] | .[0] ) as $e
    | if $e != null then $e
      else
        ($P | run($R.rulings; $T)) as $A
        | ( [ ($A.doc | tbl)[] | select(. as $x | (($A.doc | getpath($x.path) | [.. | strings | select(test("\\A<[^<>]*>\\z"))] | length) > 0)) | .t ] | .[0] ) as $ph
        | if $ph != null then "unresolved placeholder at \($ph)"
          elif $A.nopillar then "no pillar would remain"
          else empty end
      end
  end
'

JQ_APPLY='
$pf[0] as $P
| $rf[0] as $R
| ($P | tbl) as $T
| ($P | run($R.rulings; $T))
| final
'

# ---- check pass: the first failing check speaks ------------------------------
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/govern-assemble.XXXXXX")
if [ -z "$TMPD" ] || [ ! -d "$TMPD" ]; then
  printf 'govern-assemble: cannot create a temp directory\n' >&2
  TMPD=""
  exit 6
fi
if ! jq -n -r --slurpfile pf "$PROPOSAL" --slurpfile rf "$RULINGS" --arg kind "$KIND" "$JQ_DEFS $JQ_CHECK" > "$TMPD/err"; then
  printf 'govern-assemble: internal error: the rulings could not be evaluated\n' >&2
  exit 6
fi
if [ -s "$TMPD/err" ]; then
  printf 'govern-assemble: refused: ' >&2
  cat "$TMPD/err" >&2
  exit 2
fi

# ---- apply pass --------------------------------------------------------------
if [ -z "$OUT" ]; then
  if ! jq -n --slurpfile pf "$PROPOSAL" --slurpfile rf "$RULINGS" "$JQ_DEFS $JQ_APPLY"; then
    printf 'govern-assemble: internal error: the validated JSON could not be composed\n' >&2
    exit 6
  fi
  exit 0
fi

OUT_TMP="$OUT_DIR/.${OUT##*/}.assemble.$$"
if ! jq -n --slurpfile pf "$PROPOSAL" --slurpfile rf "$RULINGS" "$JQ_DEFS $JQ_APPLY" > "$OUT_TMP"; then
  printf 'govern-assemble: write failed: %s\n' "$OUT" >&2
  exit 6
fi
if ! mv -f "$OUT_TMP" "$OUT"; then
  printf 'govern-assemble: write failed: %s\n' "$OUT" >&2
  exit 6
fi
OUT_TMP=""
printf 'govern-assemble: wrote %s\n' "$OUT"
exit 0
