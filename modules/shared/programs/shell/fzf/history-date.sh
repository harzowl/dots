# The single home for the history search's presentation: the picker feeds
# `<timestamp>\t<command>` records in here (NUL-framed, so a multi-line command
# is one record) and gets `<date>\t<command>` back. The date takes one base16
# slot; the commands keep their own syntax colours, which fish_indent draws from
# the exported fish_color_* theme variables in one pass over the whole batch
# (a spawn per entry is far too slow). fzf strips the colours again on accept.
set -u

date_fmt=$'\e[38;5;8m' # base03
reset=$'\e[0m'
sep=$'\x1f'

fmt() {
  if [ -z "${1:-}" ]; then
    printf '%s' '(no timestamp)'
  else
    "@DATE@" -d "$1" '+%F %T' 2>/dev/null || printf '%s' "$1"
  fi
}

stamps=()
cmds=()
while IFS= read -r -d '' record; do
  stamp=${record%%$'\t'*}
  if [ "$stamp" = "$record" ]; then
    stamps+=('')
    cmds+=("$record")
  else
    stamps+=("$stamp")
    cmds+=("${record#"$stamp"$'\t'}")
  fi
done

total=$((${#cmds[@]}))
colored=$(mktemp)
{
  i=0
  while [ "$i" -lt "$total" ]; do
    printf '%s\n%s\n' "${cmds[$i]}" "$sep"
    i=$((i + 1))
  done
} | "@FISH_INDENT@" --only-indent --ansi 2>/dev/null >"$colored"

cmd_out=()
i=0
acc=''
while IFS= read -r line; do
  case $line in
    *"$sep"*)
      cmd_out[$i]=$acc
      i=$((i + 1))
      acc=''
      ;;
    *)
      if [ -z "$acc" ]; then acc=$line; else acc=$acc$'\n'$line; fi
      ;;
  esac
done <"$colored"
rm -f "$colored"

j=0
while [ "$j" -lt "$total" ]; do
  if [ "$i" -eq "$total" ] && [ -n "${cmd_out[$j]:-}" ]; then
    colored_cmd=${cmd_out[$j]}
  else
    colored_cmd=${cmds[$j]}
  fi
  printf '%s%s%s\t%s\0' "$date_fmt" "$(fmt "${stamps[$j]}")" "$reset" "$colored_cmd"
  j=$((j + 1))
done
