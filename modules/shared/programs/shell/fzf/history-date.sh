# The single home for the history search's presentation: the picker feeds
# `<timestamp>\t<command>` records in here (NUL-framed, so a multi-line command
# is one record) and gets `<date>\t<command>` back. The date takes one base16
# slot; the command keeps its own syntax colours, which fish_indent draws from
# the exported fish_color_* theme variables. fzf strips them again on accept.
set -u

date_fmt=$'\e[38;5;8m' # base03
reset=$'\e[0m'

fmt() {
  if [ -z "${1:-}" ]; then
    printf '%s' '(no timestamp)'
  else
    "@DATE@" -d "$1" '+%F %T' 2>/dev/null || printf '%s' "$1"
  fi
}

emit() {
  local colored
  if [ -n "${2:-}" ]; then
    colored=$("@FISH_INDENT@" --only-indent --ansi 2>/dev/null <<<"$2") || colored=$2
    [ -n "$colored" ] || colored=$2
  else
    colored=$2
  fi
  printf '%s%s%s\t%s\0' "$date_fmt" "$(fmt "$1")" "$reset" "$colored"
}

while IFS= read -r -d '' record; do
  stamp=${record%%$'\t'*}
  if [ "$stamp" = "$record" ]; then
    emit '' "$record"
  else
    emit "$stamp" "${record#"$stamp"$'\t'}"
  fi
done
