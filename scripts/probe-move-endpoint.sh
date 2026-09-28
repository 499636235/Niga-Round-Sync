#!/usr/bin/env bash
# Probe what a real WebDAV endpoint does for the move operations Round Sync will rely on.
# Runs only against a scratch directory it creates itself, and only if the base path looks
# like a test directory (override with --force). Nothing outside the probe directory is written.
#
#   scripts/probe-move-endpoint.sh --conf <rclone.conf> --remote dev --base /NAS/test
#
# Requires a rclone 1.71.0 binary (the same version the app bundles):
#   D:/Development/RoundSyncTestAssets/tools/rclone-baseline.exe
set -uo pipefail

CONF=""; REMOTE=""; BASE=""; EXE="rclone"; CORPUS="D:/Development/RoundSyncTestAssets/rs-test"; FORCE=0; CREATE_BASE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf) CONF="$2"; shift 2;;
    --remote) REMOTE="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --exe) EXE="$2"; shift 2;;
    --corpus) CORPUS="$2"; shift 2;;
    --force) FORCE=1; shift;;
    --create-base) CREATE_BASE=1; shift;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[[ -n "$CONF" && -n "$REMOTE" && -n "$BASE" ]] || { echo "need --conf --remote --base" >&2; exit 2; }
if [[ $FORCE -eq 0 && ! "$BASE" =~ (test|probe|tmp) ]]; then
  echo "refusing to write into '$BASE': the path must contain test/probe/tmp, or pass --force" >&2
  exit 2
fi

RCLONE=("$EXE" --config "$CONF")
TARGET="$REMOTE:$BASE"
say() { printf '\n=== %s ===\n' "$*"; }
verdicts=()

# --- reachability first, no writes -------------------------------------------------------
say "reachability"
if ! "${RCLONE[@]}" lsf "$TARGET/" --max-depth 1 > /dev/null 2>&1; then
  if [[ $CREATE_BASE -eq 1 ]]; then
    echo "base directory $BASE does not exist; creating it because --create-base was passed"
    "${RCLONE[@]}" mkdir "$TARGET" || exit 1
  else
    echo "cannot list $TARGET - check the remote credentials and the /dav-style prefix" >&2
    echo "(pass --create-base if this test directory is meant to be created)" >&2
    "${RCLONE[@]}" lsf "$TARGET/" --max-depth 1 2>&1 | tail -3
    exit 1
  fi
fi
"${RCLONE[@]}" size "$TARGET/" 2>&1 | tail -2

STAMP=$(date +%Y%m%d-%H%M%S)
PROBE="$TARGET/probe-$STAMP"
LOGDIR="logs/probe-$STAMP"
FIXDIR="$LOGDIR/fixtures"
mkdir -p "$FIXDIR"
say "probe area: $PROBE"
"${RCLONE[@]}" mkdir "$PROBE/inbox" "$PROBE/here" "$PROBE/conflict" || exit 1

# --- fixtures ------------------------------------------------------------------------------
cp "$CORPUS/inbox/IMG_0001_baseline.jpg" "$FIXDIR/src-a.jpg"
cp "$CORPUS/inbox/IMG_0003_UPPER.JPG"   "$FIXDIR/src-b.jpg"
cp "$CORPUS/target-conflicts/IMG_0001_baseline.jpg" "$FIXDIR/occupant-different-content.jpg"
cp "$CORPUS/inbox/IMG_0002_progressive.jpg" "$FIXDIR/occupant-same-name.jpg"
SHA_SRC_A=$(sha256sum "$FIXDIR/src-a.jpg" | cut -d' ' -f1)
SHA_OCC=$(sha256sum "$FIXDIR/occupant-different-content.jpg" | cut -d' ' -f1)
BIG="$CORPUS/inbox/big_over_budget.jpg"
SHA_BIG=$(sha256sum "$BIG" | cut -d' ' -f1)
"${RCLONE[@]}" copy "$FIXDIR" "$PROBE/inbox" > "$LOGDIR/upload.log" 2>&1 || { tail -3 "$LOGDIR/upload.log"; exit 1; }
echo "fixtures uploaded (src-a sha256 ${SHA_SRC_A:0:12}, occupant sha256 ${SHA_OCC:0:12})"

# run_move <label> <extra args...> : capture the request line the server actually saw
run_move() {
  local label="$1"; shift
  local log="$LOGDIR/${label}.log"
  echo "--- $label: rclone $* ---"
  "${RCLONE[@]}" -vv --dump headers "$@" > "$log" 2>&1
  local rc=$?
  local methods
  methods=$(grep -oE "^(DELETE|PUT|COPY|MKCOL|MOVE|PROPFIND|GET) [^ ]* HTTP/1.1" "$log" | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')
  echo "    exit=$rc  verbs: ${methods:-none}"
  grep -E "^Overwrite:|^Destination:" "$log" | sed 's/^/    /' | sort -u
  verdicts+=("$label|exit=$rc|verbs=$(echo ${methods:-none} | tr -s ' ')")
}

check_sha() { # remote path -> sha256 of what is there now
  local p="$1" out="$LOGDIR/$(basename "$p").downloaded"
  "${RCLONE[@]}" copyto "$p" "$out" > /dev/null 2>&1 || { echo "    (could not read $p)"; return 1; }
  sha256sum "$out" | cut -d' ' -f1
}

# --- S1 clean move into an existing empty directory -----------------------------------------
say "S1 move to an empty existing directory (D01/D20)"
"${RCLONE[@]}" moveto "$PROBE/inbox/src-a.jpg" "$PROBE/here/src-a.jpg" > "$LOGDIR/s1.log" 2>&1
RC=$?
grep -oE "^(DELETE|PUT|COPY|MKCOL|MOVE|GET) [^ ]* HTTP/1.1" "$LOGDIR/s1.log" | awk '{print $1}' | sort | uniq -c | tr '\n' ' '; echo " exit=$RC"
grep -E "^Overwrite:" "$LOGDIR/s1.log" | head -2
if "${RCLONE[@]}" lsf "$PROBE/inbox/src-a.jpg" >/dev/null 2>&1; then
  echo "    FAIL: source still present after moveto"; verdicts+=("S1|source-not-removed")
else
  SHA_NOW=$(check_sha "$PROBE/here/src-a.jpg")
  if [[ "${SHA_NOW:-}" == "$SHA_SRC_A" ]]; then echo "    OK: content identical after move (${SHA_NOW:0:12})"; verdicts+=("S1|moved-content-identical")
  else echo "    FAIL: content changed (${SHA_NOW:-none}) != ${SHA_SRC_A:0:12}"; verdicts+=("S1|content-changed")
  fi
fi

# --- S2 move onto a different-content target: is the occupant destroyed? ---------------------
say "S2 move onto existing different-content target (D03/D04/D05)"
"${RCLONE[@]}" moveto "$PROBE/inbox/occupant-same-name.jpg" "$PROBE/conflict/occupant-different-content.jpg" > "$LOGDIR/s2.log" 2>&1
RC=$?
grep -oE "^(DELETE|PUT|COPY|MKCOL|MOVE|GET) [^ ]* HTTP/1.1" "$LOGDIR/s2.log" | awk '{print $1}' | sort | uniq -c | tr '\n' ' '; echo " exit=$RC"
SHA_NOW=$(check_sha "$PROBE/conflict/occupant-different-content.jpg")
if [[ "${SHA_NOW:-}" == "$SHA_OCC" ]]; then
  echo "    occupant survived (target still ${SHA_OCC:0:12}); source: $("${RCLONE[@]}" lsf "$PROBE/inbox/occupant-same-name.jpg" >/dev/null 2>&1 && echo present || echo gone)"
  verdicts+=("S2|occupant-survived")
else
  echo "    OCCUPANT DESTROYED: target is now ${SHA_NOW:-none}, was ${SHA_OCC:0:12}"
  verdicts+=("S2|occupant-destroyed")
fi

# --- S3 same move with --ignore-existing ------------------------------------------------------
say "S3 --ignore-existing onto an existing target (D03)"
cp "$FIXDIR/src-b.jpg" "$FIXDIR/s3-src.jpg"
"${RCLONE[@]}" copyto "$FIXDIR/s3-src.jpg" "$PROBE/inbox/s3-src.jpg" >/dev/null 2>&1
"${RCLONE[@]}" moveto --ignore-existing "$PROBE/inbox/s3-src.jpg" "$PROBE/conflict/occupant-different-content.jpg" > "$LOGDIR/s3.log" 2>&1
RC=$?
STILL=$("${RCLONE[@]}" lsf "$PROBE/inbox/s3-src.jpg" >/dev/null 2>&1 && echo present || echo gone)
SHA_NOW=$(check_sha "$PROBE/conflict/occupant-different-content.jpg")
echo "    exit=$RC source=$STILL target sha=${SHA_NOW:0:12} (expect occupant ${SHA_OCC:0:12})"
echo "    verbs: $(grep -oE '^(DELETE|PUT|COPY|MKCOL|MOVE|GET) [^ ]* HTTP/1.1' "$LOGDIR/s3.log" | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')"
if [[ "$STILL" == present && "${SHA_NOW:-}" == "$SHA_OCC" ]]; then
  echo "    skip happened, but exit=$RC is identical to a successful move -> result is not observable"
  verdicts+=("S3|skipped-but-exit-$RC-ambiguous")
else
  echo "    --ignore-existing did NOT behave as a safe skip (source=$STILL)"
  verdicts+=("S3|ignore-existing-not-safe")
fi

# --- S4 destination parent missing: does the client MKCOL it? ---------------------------------
say "S4 move into a non-existent destination directory (D07)"
"${RCLONE[@]}" copyto "$FIXDIR/src-b.jpg" "$PROBE/inbox/src-b.jpg" >/dev/null 2>&1
"${RCLONE[@]}" moveto "$PROBE/inbox/src-b.jpg" "$PROBE/does-not-exist-yet/src-b.jpg" > "$LOGDIR/s4.log" 2>&1
RC=$?
echo "    exit=$RC  MKCOL seen: $(grep -cE "^MKCOL " "$LOGDIR/s4.log")"
if "${RCLONE[@]}" lsf "$PROBE/does-not-exist-yet/" --max-depth 1 >/dev/null 2>&1; then
  echo "    directory was created by the move path"
  verdicts+=("S4|client-created-missing-parent")
else
  echo "    directory still absent"
  verdicts+=("S4|no-directory-created")
fi

# --- S5 large file: server-side verb only, or client relay? ----------------------------------
say "S5 move a large file and watch wire bytes (D11)"
"${RCLONE[@]}" copyto "$BIG" "$PROBE/inbox/big_over_budget.jpg" > "$LOGDIR/s5-upload.log" 2>&1
BIGNAME="big_over_budget.jpg"
START=$(date +%s)
"${RCLONE[@]}" -vv --use-json-log --stats 1s --stats-one-line moveto "$PROBE/inbox/$BIGNAME" "$PROBE/here/$BIGNAME" > "$LOGDIR/s5.log" 2>&1
RC=$?
echo "    exit=$RC wall=$(( $(date +%s) - START ))s"
grep -oE "\{.*transfers.*\}" "$LOGDIR/s5.log" | tail -2 | sed 's/^/    /'
echo "    verbs: $(grep -oE '^(DELETE|PUT|COPY|MKCOL|MOVE|GET|HEAD) [^ ]* HTTP/1.1' "$LOGDIR/s5.log" | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')"
SHA_NOW=$(check_sha "$PROBE/here/$BIGNAME")
[[ "${SHA_NOW:-}" == "$SHA_BIG" ]] && echo "    OK: big file bytes intact after move" && verdicts+=("S5|big-moved-content-identical") \
  || { echo "    big file sha=${SHA_NOW:-none} expected ${SHA_BIG:0:12}"; verdicts+=("S5|big-check-inconclusive"); }

say "verdicts"
printf '%s\n' "${verdicts[@]}"
echo
echo "probe left in place for manual inspection: $PROBE"
echo "raw request logs: $LOGDIR"
