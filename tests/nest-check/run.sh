#!/usr/bin/env bash
# Exercise scripts/check-nest.sh against the fixtures here.
#
# Positive `cases/*.case` must exit 1 with stdout byte-equal to
# `expected/<stem>.expected`; `cases/negatives/*.case` must exit 0 with empty
# stdout. Negatives are explicit entries, so a false positive fails the run —
# it can never pass vacuously.
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$dir/../.." && pwd)
checker="$root/scripts/check-nest.sh"

if [ ! -f "$checker" ]; then
  echo "check-nest: checker not found: $checker" >&2
  exit 1
fi

shopt -s nullglob
positive=("$dir"/cases/*.case)
negative=("$dir"/cases/negatives/*.case)

passed=0
total=0
failed=0

# Compare byte-for-byte, so run from here and pass a stable relative path.
cd "$dir"
out=$(mktemp)
trap 'rm -f "$out"' EXIT

for case in "${positive[@]}"; do
  total=$((total + 1))
  stem=$(basename "$case" .case)
  expected="$dir/expected/$stem.expected"
  if [ ! -f "$expected" ]; then
    echo "FAIL $stem: missing $expected" >&2
    failed=$((failed + 1))
    continue
  fi
  bash "$checker" "cases/$stem.case" >"$out" 2>/dev/null
  rc=$?
  if [ "$rc" -eq 1 ] && cmp -s "$out" "$expected"; then
    passed=$((passed + 1))
  else
    echo "FAIL $stem: exit $rc, got:" >&2
    cat "$out" >&2
    echo "want: match $expected and exit 1" >&2
    failed=$((failed + 1))
  fi
done

for case in "${negative[@]}"; do
  total=$((total + 1))
  stem=$(basename "$case" .case)
  bash "$checker" "$case" >"$out" 2>/dev/null
  rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$out" ]; then
    passed=$((passed + 1))
  else
    echo "FAIL $stem (negative): exit $rc, got:" >&2
    cat "$out" >&2
    echo "want: empty stdout and exit 0" >&2
    failed=$((failed + 1))
  fi
done

echo "$passed/$total passed"
[ "$failed" -eq 0 ] || exit 1
