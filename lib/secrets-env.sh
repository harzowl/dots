#!/bin/sh
# Build a dotenv of `NAME=value` pairs from a secret store, so a service that
# only reads prefixed env vars can consume neutrally named secrets without the
# values touching the Nix store.
#
# Usage: secrets-env.sh OUT SOURCE... -- NAME=SECRET...
#   OUT          file to write (mode 0600)
#   SOURCE...    dotenv files to look the secrets up in, in order
#   NAME=SECRET  pairs: emit `NAME=` with the value of SECRET
#
# A missing secret emits an empty value (the service's own default/validation
# decides what that means).
set -eu
umask 077

out=$1
shift

sources=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--' ]; then
    shift
    break
  fi
  sources="$sources $1"
  shift
done

lookup() {
  for f in $sources; do
    v=$(sed -n "s/^$1=//p" "$f" | head -n 1)
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
}

tmp="${out}.tmp"
: > "$tmp"
for pair in "$@"; do
  name=${pair%%=*}
  secret=${pair#*=}
  printf '%s=%s\n' "$name" "$(lookup "$secret")" >> "$tmp"
done
chmod 600 "$tmp"
mv "$tmp" "$out"
