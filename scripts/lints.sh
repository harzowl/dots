#!/usr/bin/env bash
# Run statix and deadnix over the given paths (files or directories), reporting
# both and exiting non-zero on any finding. Used by `nix flake check` and the
# pre-commit hook.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: lints.sh FILE_OR_DIR..." >&2
  exit 2
fi

status=0
for path in "$@"; do
  statix check "$path" || status=1
done
deadnix --fail "$@" || status=1
exit "$status"
