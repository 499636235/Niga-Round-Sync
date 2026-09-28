#!/usr/bin/env bash
# Probe what a real WebDAV endpoint does for the move operations Round Sync will rely on.
# Everything is written under a scratch directory this script creates itself, and it only
# runs against a base path that looks like a test directory (override with --force).
#
#   scripts/probe-move-endpoint.sh --conf <rclone.conf> --remote dev --base /rs-test --create-base
#
# Use the rclone build that matches the bundled one (1.71.0):
#   D:/Development/RoundSyncTestAssets/tools/rclone-baseline.exe
#
# Each scenario logs the full request stream (-vv --dump headers), so the verdicts are backed
# by the verbs the server actually saw, not by the exit code alone.
set -uo pipefail

CONF=""; REMOTE=""; BASE=""; EXE="rclone"; CORPUS="D:/Development/RoundSyncTestAssets/rs-test"
FORCE=0; CREATE_BASE=0; KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf) CONF="$2"; shift 2;;
    --remote) REMOTE="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --exe) EXE="$2"; shift 2;;
    --corpus) CORPUS="$2"; shift 2;;
    --force) FORCE=1; shift;;
    --create-base) CREATE_BASE=1; shift;;
    --keep) KEEP=1; shift;;
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
STAMP=$(date +%Y%m%d-%H%M%S)
LOGDIR="logs/probe-$STAMP"
FIXDIR="$LOGDIR/fixtures"
mkdir -p "$FIXDIR"
verdicts=()

say() { printf '\n=== %s ===\n' "$*"; }

# verbs <logfile> : the request verbs the client actually sent, in order
verbs() {
  grep -oE "DEBUG : (MOVE|MKCOL|DELETE|PUT|COPY|GET|HEAD|PROPFIND|OPTIONS) [^ ]+ HTTP" "$1" 2>/dev/null \
    | sed -E 's/DEBUG : ([A-Z]+) .*/\1/' | uniq -c | tr -s ' \n' ' '
}

# scenario <label> <args...> : run one rclone invocation with the full request dump
scenario() {
  local label="$1"; shift
  local log="$LOGDIR/$label.log"
  "${RCLONE[@]}" -vv --dump headers "$@" > "$log" 2>&1
  local rc=$?
  echo "  exit=$rc  verbs:$(verbs "$log")"
  grep -hE "^(Overwrite|Destination|Depth):" "$log" | sed 's/^/     header: /' | sort | uniq -c | sed 's/^/    /'
  return $rc
}

sha_of_remote() { # sha256 of a remote file, or empty when it cannot be read
  local path="$1"
  local out="$FIXDIR/$(basename "$path").readback"
  if "${RCLONE[@]}" copyto "$path" "$out" > /dev/null 2>&1; then
    sha256sum "$out" | cut -d' ' -f1
  fi
}

remote_exists() { "${RCLONE[@]}" lsf "$1" > /dev/null 2>&1; }

# --- reachability --------------------------------------------------------------------------
say "reachability"
if ! "${RCLONE[@]}" lsf "$TARGET/" --max-depth 1 > /dev/null 2>&1; then
  if [[ $CREATE_BASE -eq 1 ]]; then
    echo "creating base $BASE (asked for with --create-base)"
    "${RCLONE[@]}" mkdir "$TARGET" || exit 1
  else
    echo "cannot list $TARGET (credentials? url prefix? pass --create-base to make it)" >&2
    "${RCLONE[@]}" lsf "$TARGET/" --max-depth 1 2>&1 | tail -2
    exit 1
  fi
fi
PROBE="$TARGET/probe-$STAMP"
say "probe area: $PROBE"
for d in inbox here conflict; do
  "${RCLONE[@]}" mkdir "$PROBE/$d" || exit 1
done

# --- fixtures ------------------------------------------------------------------------------
cp "$CORPUS/inbox/IMG_0001_baseline.jpg" "$FIXDIR/src-a.jpg"
cp "$CORPUS/inbox/IMG_0003_UPPER.JPG"   "$FIXDIR/src-b.jpg"
cp "$CORPUS/target-conflicts/IMG_0001_baseline.jpg" "$FIXDIR/occupant.jpg"
SHA_SRC_A=$(sha256sum "$FIXDIR/src-a.jpg" | cut -d' ' -f1)
SHA_SRC_B=$(sha256sum "$FIXDIR/src-b.jpg" | cut -d' ' -f1)
SHA_OCC=$(sha256sum "$FIXDIR/occupant.jpg" | cut -d' ' -f1)
BIG="$CORPUS/inbox/big_over_budget.jpg"
SHA_BIG=$(sha256sum "$BIG" | cut -d' ' -f1)

for f in src-a.jpg src-b.jpg occupant.jpg; do
  "${RCLONE[@]}" copyto "$FIXDIR/$f" "$PROBE/inbox/$f" > "$LOGDIR/upload-$f.log" 2>&1 || { echo "upload failed"; tail -2 "$LOGDIR/upload-$f.log"; exit 1; }
done
# occupant.jpg also sits at the conflict target under its own name, and src-a will be moved
# onto a same-named target that already holds different bytes.
"${RCLONE[@]}" copyto "$FIXDIR/occupant.jpg" "$PROBE/conflict/src-a.jpg" > /dev/null 2>&1
echo "fixtures: src-a=${SHA_SRC_A:0:12} src-b=${SHA_SRC_B:0:12} occupant=${SHA_OCC:0:12}"

# --- S1 clean move into an existing empty directory (D01 / D20) -----------------------------
say "S1 move to an empty existing directory"
scenario s1 moveto "$PROBE/inbox/src-a.jpg" "$PROBE/here/src-a.jpg"
if remote_exists "$PROBE/inbox/src-a.jpg"; then
  echo "  FAIL: source still present"; verdicts+=("S1|source-not-removed")
else
  now=$(sha_of_remote "$PROBE/here/src-a.jpg")
  if [[ "${now:-}" == "$SHA_SRC_A" ]]; then
    echo "  OK: moved, bytes identical"; verdicts+=("S1|moved-bytes-identical")
  else
    echo "  FAIL: bytes changed to ${now:-none}"; verdicts+=("S1|bytes-changed")
  fi
fi

# --- S2 move onto an existing different-content target (D03 / D04 / D05) --------------------
say "S2 move onto existing target holding different bytes"
scenario s2 moveto "$PROBE/inbox/src-b.jpg" "$PROBE/conflict/src-a.jpg"
now=$(sha_of_remote "$PROBE/conflict/src-a.jpg")
if [[ "${now:-}" == "$SHA_OCC" ]]; then
  echo "  occupant survived; source: $(remote_exists "$PROBE/inbox/src-b.jpg" && echo present || echo gone)"
  verdicts+=("S2|occupant-survived")
else
  echo "  OCCUPANT DESTROYED: target is ${now:-unreadable}, was $SHA_OCC"
  echo "  verbs above show whether a DELETE preceded the MOVE"
  verdicts+=("S2|occupant-destroyed")
fi

# --- S3 --ignore-existing onto an existing target -------------------------------------------
say "S3 --ignore-existing onto an existing target"
"${RCLONE[@]}" copyto "$FIXDIR/src-b.jpg" "$PROBE/inbox/src-c.jpg" > /dev/null 2>&1
before=$(sha_of_remote "$PROBE/conflict/src-a.jpg")
scenario s3 moveto --ignore-existing "$PROBE/inbox/src-c.jpg" "$PROBE/conflict/src-a.jpg"
after=$(sha_of_remote "$PROBE/conflict/src-a.jpg")
moved=gone; remote_exists "$PROBE/inbox/src-c.jpg" && moved=present
echo "  source=$moved  target before=${before:0:12} after=${after:0:12}"
if [[ "$moved" == present && "${before:-}" == "${after:-}" ]]; then
  echo "  skipped safely, BUT exit code is 0 - identical to a real move, so the app cannot tell them apart"
  verdicts+=("S3|skipped-but-exit-0-ambiguous")
else
  echo "  NOT a safe skip (source=$moved target changed=${before:0:12}->${after:0:12})"
  verdicts+=("S3|ignore-existing-not-safe")
fi

# --- S4 destination parent missing (D07) -----------------------------------------------------
say "S4 move into a destination directory that does not exist"
"${RCLONE[@]}" copyto "$FIXDIR/src-a.jpg" "$PROBE/inbox/src-d.jpg" > /dev/null 2>&1
scenario s4 moveto "$PROBE/inbox/src-d.jpg" "$PROBE/no-such-dir/src-d.jpg"
if remote_exists "$PROBE/no-such-dir/"; then
  echo "  directory was created by the move path (plan forbids auto-MKCOL)"
  verdicts+=("S4|client-created-missing-parent")
else
  echo "  directory still absent"; verdicts+=("S4|no-directory-created")
fi

# --- S5 large file: server side or client relay (D11) ----------------------------------------
say "S5 move a large file and check whether bytes crossed the phone"
"${RCLONE[@]}" copyto "$BIG" "$PROBE/inbox/big.jpg" > "$LOGDIR/s5-upload.log" 2>&1
START=$(date +%s)
scenario s5 moveto --use-json-log --stats 1s --stats-one-line "$PROBE/inbox/big.jpg" "$PROBE/here/big.jpg"
WALL=$(( $(date +%s) - START ))
last=$(grep -oE '\{.*"stats".*\}' "$LOGDIR/s5.log" | tail -1)
echo "  wall=${WALL}s  stats: $(echo "$last" | grep -oE '"(serverSideMoves|serverSideMoveBytes|transfers|bytes|speed)":[^,}]*' | tr '\n' ' ')"
now=$(sha_of_remote "$PROBE/here/big.jpg")
if [[ "${now:-}" == "$SHA_BIG" ]]; then
  echo "  bytes intact after move"
  if [[ $WALL -lt 20 ]]; then echo "  94 MiB in ${WALL}s => server side rename, no client relay"; verdicts+=("S5|server-side-move-intact")
  else verdicts+=("S5|intact-but-slow-${WALL}s"); fi
else
  echo "  FAIL: big file sha=${now:-none}"; verdicts+=("S5|bytes-changed")
fi

# --- S6 source equals destination (D08) -------------------------------------------------------
say "S6 move a file onto itself"
"${RCLONE[@]}" copyto "$FIXDIR/src-a.jpg" "$PROBE/inbox/self.jpg" > /dev/null 2>&1
scenario s6 moveto "$PROBE/inbox/self.jpg" "$PROBE/inbox/self.jpg"
if remote_exists "$PROBE/inbox/self.jpg"; then
  now=$(sha_of_remote "$PROBE/inbox/self.jpg")
  [[ "${now:-}" == "$SHA_SRC_A" ]] && { echo "  file survived a same-location move intact"; verdicts+=("S6|same-location-harmless"); } \
    || { echo "  FAIL: file changed by its own move"; verdicts+=("S6|same-location-damaged"); }
else
  echo "  FAIL: file disappeared"; verdicts+=("S6|same-location-lost-file")
fi

# --- teardown ---------------------------------------------------------------------------------
say "cleanup"
if [[ $KEEP -eq 1 ]]; then
  echo "  --keep given: leaving $PROBE in place"
else
  "${RCLONE[@]}" purge "$PROBE" > "$LOGDIR/purge.log" 2>&1 && echo "  purged $PROBE" || echo "  purge failed, see $LOGDIR/purge.log"
fi

say "verdicts"
printf '  %s\n' "${verdicts[@]}"
echo "  request logs: $LOGDIR"
