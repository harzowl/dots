#!/usr/bin/env bash
# Exercise scripts/personal-data-guard.sh against the fixtures here.
#
# The committer identity is injected as a synthetic one via PDG_* so no real
# value is ever stored: cases/*.txt must be flagged (exit 1),
# cases/negatives/*.txt must be clean (exit 0).
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$dir/../.." && pwd)
guard="$root/scripts/personal-data-guard.sh"

if [ ! -f "$guard" ]; then
  echo "personal-data-test: guard not found: $guard" >&2
  exit 1
fi

export PDG_EMAIL="leakyuser@privatecorp.example"
export PDG_FQDN="host.privatecorp.example"
export PDG_USER="leakyuser"

shopt -s nullglob
positive=("$dir"/cases/*.txt)
negative=("$dir"/cases/negatives/*.txt)

fail=0
for case_file in "${positive[@]}"; do
  if bash "$guard" "$case_file" >/dev/null 2>&1; then
    echo "FAIL (expected a finding): ${case_file#"$dir"/}" >&2
    fail=1
  fi
done
for case_file in "${negative[@]}"; do
  if ! bash "$guard" "$case_file" >/dev/null 2>&1; then
    echo "FAIL (expected clean): ${case_file#"$dir"/}" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

# A GitHub noreply identity must not flag its generic `users` label. Run the
# fixture under a noreply identity separately, since the run above injects one
# synthetic identity for all cases.
if ! PDG_EMAIL="123+someone@users.noreply.github.com" PDG_FQDN="host.example" PDG_USER="someone" \
  bash "$guard" "$dir/cases/negatives/noreply-users.txt" >/dev/null 2>&1; then
  echo "FAIL (a noreply identity must be ignored)" >&2
  exit 1
fi

echo "personal-data-test: ${#positive[@]} positive, ${#negative[@]} negative — all pass" >&2
