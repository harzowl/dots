#!/usr/bin/env bash
# Exercise scripts/secret-scan.py's personal-email rule against the fixtures
# here.
#
# cases/*.case must be flagged (exit 1); cases/negatives/*.case must be clean
# (exit 0). Fixtures deliberately use suffixes outside the scanner's
# SCAN_SUFFIXES so the repo's own `nix flake check` directory walk never trips
# on its own test data.
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$dir/../.." && pwd)
scanner="$root/scripts/secret-scan.py"

if [ ! -f "$scanner" ]; then
  echo "secret-scan-test: scanner not found: $scanner" >&2
  exit 1
fi

shopt -s nullglob
positive=("$dir"/cases/*.case)
negative=("$dir"/cases/negatives/*.case)

fail=0
for case_file in "${positive[@]}"; do
  if out=$(python3 "$scanner" "$case_file" 2>&1); then
    echo "FAIL (expected a finding): ${case_file#"$dir"/}" >&2
    fail=1
  fi
done
for case_file in "${negative[@]}"; do
  if ! out=$(python3 "$scanner" "$case_file" 2>&1); then
    echo "FAIL (expected clean): ${case_file#"$dir"/}" >&2
    echo "$out" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "secret-scan-test: ${#positive[@]} positive, ${#negative[@]} negative — all pass" >&2
