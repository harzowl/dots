# The single home for the history search's presentation: the picker feeds
# `<timestamp>\t<command>` records in here (NUL-framed, so a multi-line command
# is one record) and gets a coloured `<date>\t<command>` back. GNU `date`
# normalises the timestamp; colours are base16 palette slots, so they follow the
# terminal's scheme rather than hardcoding hex. fzf strips the colours on accept.
set -u

date_fmt=$'\e[38;5;8m' # base03
cmd_fmt=$'\e[38;5;2m'  # base0b
reset=$'\e[0m'

fmt() {
  if [ -z "${1:-}" ]; then
    printf '%s' '(no timestamp)'
  else
    "@DATE@" -d "$1" '+%F %T' 2>/dev/null || printf '%s' "$1"
  fi
}

while IFS= read -r -d '' record; do
  stamp=${record%%$'\t'*}
  if [ "$stamp" = "$record" ]; then
    stamp=''
    cmd=$record
  else
    cmd=${record#"$stamp"$'\t'}
  fi
  printf '%s%s%s\t%s%s%s\0' "$date_fmt" "$(fmt "$stamp")" "$reset" "$cmd_fmt" "$cmd" "$reset"
done
