#!/usr/bin/env bash
# Exercise slskd-import.py against fake `beet` binaries. The importer must
# treat duplicate/skip and per-album errors as handled outcomes: exit 0, write
# a marker, and never hand the same album to beets twice.
set -uo pipefail

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$dir/../.." && pwd)
importer="$root/modules/system/services/download/slskd-import/slskd-import.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failed=0
passed=0

check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
  else
    echo "FAIL $name: got '$got', want '$want'" >&2
    failed=$((failed + 1))
  fi
}

check_absent() {
  local name=$1 path=$2
  if [ ! -e "$path" ]; then
    passed=$((passed + 1))
  else
    echo "FAIL $name: still present: $path" >&2
    failed=$((failed + 1))
  fi
}

check_marker() {
  local name=$1 path=$2 want=$3
  if python3 - "$path" "$want" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["outcome"] == sys.argv[2], record
assert record["time"].endswith("Z"), record
PY
  then
    passed=$((passed + 1))
  else
    echo "FAIL $name: bad marker $path" >&2
    failed=$((failed + 1))
  fi
}

make_album() {
  local album=$1
  mkdir -p "$album"
  : >"$album/01 - Track.flac"
  : >"$album/02 - Track.flac"
  : >"$album/cover.jpg"
  : >"$album/playlist.m3u"
}

run_import() {
  python3 "$importer" \
    --complete "$1" \
    --incomplete "$tmp/incomplete" \
    --beet "$2" \
    --settle 0 \
    "${@:3}"
}

bash_path=$(command -v bash)

cat >"$tmp/beet-duplicate" <<EOF
#!$bash_path
echo "\$@" >>"\$BEET_LOG"
echo "Skipping."
exit 0
EOF
chmod +x "$tmp/beet-duplicate"

cat >"$tmp/beet-import" <<EOF
#!$bash_path
echo "\$@" >>"\$BEET_LOG"
album=\${!#}
find "\$album" -type f -name '*.flac' -exec mv -t "\$IMPORTED_DIR" {} +
exit 0
EOF
chmod +x "$tmp/beet-import"

cat >"$tmp/beet-error" <<EOF
#!$bash_path
echo "\$@" >>"\$BEET_LOG"
echo "beet exploded" >&2
exit 2
EOF
chmod +x "$tmp/beet-error"

export BEET_LOG="$tmp/imports.log"

# Duplicate/skip: audio stays, the run succeeds, and the marker stops a retry.
complete="$tmp/duplicate/complete"
album="$complete/dummy-user/directories/Artist/Album"
make_album "$album"
: >"$BEET_LOG"
if run_import "$complete" "$tmp/beet-duplicate" >"$tmp/duplicate.out" 2>&1; then
  passed=$((passed + 1))
else
  echo "FAIL duplicate: importer exited non-zero" >&2
  cat "$tmp/duplicate.out" >&2
  failed=$((failed + 1))
fi
check "duplicate marker written" 1 "$(test -f "$album/.slskd-imported" && echo 1 || echo 0)"
check_marker "duplicate marker" "$album/.slskd-imported" duplicate
check "duplicate audio kept" 2 "$(find "$album" -maxdepth 1 -name '*.flac' | wc -l)"
check "duplicate imported once" 1 "$(wc -l <"$BEET_LOG")"

if run_import "$complete" "$tmp/beet-duplicate" >"$tmp/duplicate-again.out" 2>&1; then
  passed=$((passed + 1))
else
  echo "FAIL duplicate retry: importer exited non-zero" >&2
  failed=$((failed + 1))
fi
check "duplicate not imported again" 1 "$(wc -l <"$BEET_LOG")"
check "duplicate retry logged" 1 "$(grep -c 'already handled' "$tmp/duplicate-again.out")"

# Normal import: audio is moved out, sidecars are removed, the album is pruned.
complete="$tmp/normal/complete"
album="$complete/dummy-user/directories/Artist/Album"
make_album "$album"
export IMPORTED_DIR="$tmp/normal/imported"
mkdir -p "$IMPORTED_DIR"
: >"$BEET_LOG"
if run_import "$complete" "$tmp/beet-import" >"$tmp/normal.out" 2>&1; then
  passed=$((passed + 1))
else
  echo "FAIL normal: importer exited non-zero" >&2
  cat "$tmp/normal.out" >&2
  failed=$((failed + 1))
fi
check "normal import moved audio" 2 "$(find "$IMPORTED_DIR" -name '*.flac' | wc -l)"
check_absent "normal import pruned album" "$album"
check_absent "normal import pruned empty parents" "$complete/dummy-user"

# Without the flag a top-level album is still a legacy user root and is skipped.
complete="$tmp/legacy/complete"
album="$complete/Artist - Album (2020)"
make_album "$album"
: >"$BEET_LOG"
if run_import "$complete" "$tmp/beet-import" >"$tmp/legacy.out" 2>&1; then
  passed=$((passed + 1))
else
  echo "FAIL legacy: importer exited non-zero" >&2
  failed=$((failed + 1))
fi
check "legacy top-level skipped" 1 "$(grep -c 'skip legacy' "$tmp/legacy.out")"
check "legacy top-level not imported" 0 "$(wc -l <"$BEET_LOG")"
check "legacy top-level kept" 1 "$(test -d "$album" && echo 1 || echo 0)"

# A staged album has no `directories` segment: with the flag, a top-level
# directory that holds audio is an album root and is imported and pruned.
complete="$tmp/staged/complete"
album="$complete/Artist - Album (2020)"
make_album "$album"
export IMPORTED_DIR="$tmp/staged/imported"
mkdir -p "$IMPORTED_DIR"
: >"$BEET_LOG"
if run_import "$complete" "$tmp/beet-import" --top-level-albums >"$tmp/staged.out" 2>&1; then
  passed=$((passed + 1))
else
  echo "FAIL staged: importer exited non-zero" >&2
  cat "$tmp/staged.out" >&2
  failed=$((failed + 1))
fi
check "staged import moved audio" 2 "$(find "$IMPORTED_DIR" -name '*.flac' | wc -l)"
check_absent "staged import pruned album" "$album"

# Stale cleanup: old incomplete trees and marked complete albums go, unmarked
# albums waiting for import stay.
mkdir -p "$tmp/incomplete/stale-user/Artist/Album" "$tmp/incomplete/recent-user/Artist/Album"
: >"$tmp/incomplete/stale-user/Artist/Album/01.part"
: >"$tmp/incomplete/recent-user/Artist/Album/01.part"
touch -d '2 hours ago' \
  "$tmp/incomplete/stale-user/Artist/Album/01.part" \
  "$tmp/incomplete/stale-user/Artist/Album" \
  "$tmp/incomplete/stale-user/Artist" \
  "$tmp/incomplete/stale-user"
complete="$tmp/stale/complete"
marked="$complete/dummy-user/directories/Artist/Marked"
unmarked="$complete/dummy-user/directories/Artist/Unmarked"
empty="$complete/dummy-user/directories/Artist/EmptyOld"
make_album "$marked"
make_album "$unmarked"
mkdir -p "$empty"
printf '%s\n' '{"outcome": "duplicate", "time": "2020-01-01T00:00:00Z"}' >"$marked/.slskd-imported"
find "$marked" "$unmarked" -type f -exec touch -d '2 hours ago' {} +
touch -d '2 hours ago' "$marked" "$unmarked"
if run_import "$complete" "$tmp/beet-error" --stale-after 1 >"$tmp/stale.out" 2>&1; then
  passed=$((passed + 1))
else
  echo "FAIL stale: importer exited non-zero" >&2
  cat "$tmp/stale.out" >&2
  failed=$((failed + 1))
fi
check_absent "stale marked album removed" "$marked"
check "unmarked old album kept" 1 "$(test -d "$unmarked" && echo 1 || echo 0)"
check_absent "stale incomplete removed" "$tmp/incomplete/stale-user"
check "recent incomplete kept" 1 "$(test -d "$tmp/incomplete/recent-user" && echo 1 || echo 0)"
check_absent "empty dir removed" "$empty"

# Genuine per-album error: logged, marked, and the run still succeeds.
complete="$tmp/error/complete"
album="$complete/dummy-user/directories/Artist/Album"
make_album "$album"
: >"$BEET_LOG"
if run_import "$complete" "$tmp/beet-error" >"$tmp/error.out" 2>&1; then
  passed=$((passed + 1))
else
  echo "FAIL error: importer exited non-zero" >&2
  cat "$tmp/error.out" >&2
  failed=$((failed + 1))
fi
check_marker "error marker" "$album/.slskd-imported" error
check "error logged" 1 "$(grep -c 'beet import failed' "$tmp/error.out")"
if run_import "$complete" "$tmp/beet-error" >"$tmp/error-again.out" 2>&1; then
  passed=$((passed + 1))
else
  echo "FAIL error retry: importer exited non-zero" >&2
  failed=$((failed + 1))
fi
check "error not imported again" 1 "$(wc -l <"$BEET_LOG")"

# Systemic errors still fail the oneshot.
if run_import "$complete" "$tmp/does-not-exist" >"$tmp/missing.out" 2>&1; then
  echo "FAIL missing beet: importer exited zero" >&2
  failed=$((failed + 1))
else
  passed=$((passed + 1))
fi

if run_import "$tmp/does-not-exist" "$tmp/beet-duplicate" >"$tmp/no-root.out" 2>&1; then
  echo "FAIL missing complete root: importer exited zero" >&2
  failed=$((failed + 1))
else
  passed=$((passed + 1))
fi

echo "$passed/$((passed + failed)) passed"
[ "$failed" -eq 0 ]
