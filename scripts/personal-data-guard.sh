#!/usr/bin/env bash
# Fail when a file carries the committer's own identity: their email address,
# its domain and registrable label, the machine's FQDN, or their login name.
#
# Everything is derived from git/the environment at run time, so no private
# value is stored here and it stays correct as identities change; PDG_* lets
# the test suite inject a synthetic identity instead. This is the local
# counterpart to scripts/secret-scan.py (which enforces reserved example
# domains over the whole tree) and is what the pre-commit hook runs. LICENSE is
# exempt: the retained copyright attribution is intentionally allowed to name
# the author.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: personal-data-guard.sh FILE..." >&2
  exit 2
fi

ere_escape() { printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'; }

email="${PDG_EMAIL:-}"
if [ -z "$email" ]; then
  email=$(git config --get user.email 2>/dev/null || true)
fi

fqdn="${PDG_FQDN:-}"
if [ -z "$fqdn" ]; then
  fqdn=$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)
fi

login="${PDG_USER:-${USER:-${LOGNAME:-}}}"

domain=""
label=""
if [[ "$email" == *@* ]]; then
  domain="${email##*@}"
  label="${domain%%.*}"
fi

# A bare label only matches safely when it is distinctive: skip public mail
# providers (ordinary prose) and short or dotless domains.
if [[ "$domain" != *.* || ${#label} -lt 4 ]]; then
  label=""
fi
case "$label" in
  gmail | outlook | hotmail | yahoo | icloud | proton | protonmail | live | msn | aol | gmx) label="" ;;
esac

# A login shorter than four characters is too common a word to match safely.
if [ "${#login}" -lt 4 ]; then
  login=""
fi

ci_needles=()
[ -n "$email" ] && ci_needles+=("$email")
[ -n "$domain" ] && ci_needles+=("$domain")
[ -n "$fqdn" ] && ci_needles+=("$fqdn")

# One -e per needle: a single -e would bind only the first and treat the rest
# as filenames.
ci_fixed=()
for needle in ${ci_needles[@]+"${ci_needles[@]}"}; do
  ci_fixed+=(-e "$needle")
done

label_re=$(ere_escape "$label")
login_re=$(ere_escape "$login")

found=0
for f in "$@"; do
  case "$f" in LICENSE | */LICENSE) continue ;; esac
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue

  if [ "${#ci_needles[@]}" -gt 0 ] && grep -nIiF "${ci_fixed[@]}" "$f" >&2; then
    found=1
  fi
  if [ -n "$label" ] && grep -nIiE "\\b${label_re}\\b" "$f" >&2; then
    found=1
  fi
  if [ -n "$login" ] && grep -nE "\\b${login_re}\\b" "$f" >&2; then
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  echo "personal-data-guard: the committer's own identity appears above; use a dummy (dummy-DO-NOT-USE-...) or a reserved example address" >&2
  exit 1
fi
exit 0
