#!/usr/bin/env bash
# The email derivation table for a mirrored Navidrome account:
#   email -> as-is (any domain), bare username -> domain, non-email -> none.
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$dir/../.." && pwd)
# shellcheck source=../modules/system/services/music/navidrome/derive-email.sh
. "$root/modules/system/services/music/navidrome/derive-email.sh"

failed=0
passed=0

check() {
  local name=$1 want=$2
  shift 2
  local got
  got=$(derive_email "$@")
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
  else
    echo "FAIL $name: got '$got', want '$want'" >&2
    failed=$((failed + 1))
  fi
}

check "foreign email field as-is" "someone@mail.example.com" "someone@mail.example.com" "" "example.test"
check "foreign email username as-is" "someone@mail.example.com" "someone@mail.example.com" "" "example.test"
check "bare username gets the domain" "someone@example.test" "someone" "" "example.test"
check "bare username with a dot" "some.one@example.test" "some.one" "" "example.test"
check "bare username with no domain configured" "" "someone" "" ""
check "non-email username gets none" "" "some one" "" "example.test"
check "at-sign but not an address gets none" "" "someone@localhost" "" "example.test"
check "empty username gets none" "" "" "" "example.test"
check "email field wins over a different username" "other@example.net" "someone@mail.example.com" "other@example.net" "example.test"

echo "$passed/$((passed + failed)) passed"
[ "$failed" -eq 0 ]
