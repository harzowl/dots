#!/bin/sh
set -eu

theme=/usr/local/searxng/searx/static/themes/simple
marker='/* searxng-custom-css */'
found=0

for file in "$theme"/sxng-ltr.min.css "$theme"/sxng-rtl.min.css; do
  [ -f "$file" ] || continue
  found=1
  # WhiteNoise prefers these stale variants over the appended stylesheet.
  rm -f "$file".gz "$file".br "$file".zst
  if grep -qF "$marker" "$file"; then
    continue
  fi
  {
    printf '\n%s\n' "$marker"
    cat /usr/local/searxng/custom.css
    printf '\n'
  } >> "$file"
done

if [ "$found" -eq 0 ]; then
  echo "searxng-custom-css: no theme stylesheet found under $theme" >&2
fi

exec /usr/local/bin/run.sh
