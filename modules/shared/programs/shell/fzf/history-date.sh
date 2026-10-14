# The single home for the history search's date column. A shell's own reader
# feeds `<epoch>\t<command>` here and gets `<local date>\t<command>` back; the
# zsh and bash readers live here too so no shell repeats the formatting.
#
# Records are NUL-framed and the command is never touched, so a multi-line
# command survives as one record. The module wires in GNU coreutils' `date`
# (BSD/macOS `date` syntax is not supported).
set -u

fmt() {
  if [ -z "${1:-}" ]; then
    printf '%s' '(no timestamp)'
  else
    "@DATE@" -d "@$1" '+%F %T' 2>/dev/null || printf '%s' "$1"
  fi
}

emit() { printf '%s\t%s\0' "$(fmt "$1")" "$2"; }

# `: <epoch>:<duration>;<command>` per entry; a line without the `: ` prefix is
# a continuation, which is how zsh stores a command that spans several lines.
read_zsh() {
  local line epoch='' cmd='' have=0 meta
  while IFS= read -r line; do
    case $line in
      ': '*)
        [ "$have" = 1 ] && emit "$epoch" "$cmd"
        meta=${line#': '}
        epoch=${meta%%:*}
        cmd=${meta#*;}
        have=1
        ;;
      *) cmd=$cmd$'\n'$line ;;
    esac
  done < "$1"
  [ "$have" = 1 ] && emit "$epoch" "$cmd"
}

# bash writes a bare `#<epoch>` marker before a command only when
# HISTTIMEFORMAT is set; that marker dates the line after it. Without markers
# the date is unknown, and bash stores no line-continuation, so a multi-line
# command reads back as its separate lines.
read_bash() {
  local line epoch=''
  while IFS= read -r line; do
    case $line in
      '#'*)
        if [[ $line =~ ^\#([0-9]+)$ ]]; then
          epoch=${BASH_REMATCH[1]}
          continue
        fi
        ;;
    esac
    emit "$epoch" "$line"
  done < "$1"
}

case ${1:-} in
  --zsh) read_zsh "$2" ;;
  --bash) read_bash "$2" ;;
  *)
    while IFS= read -r -d '' record; do
      epoch=${record%%$'\t'*}
      if [ "$epoch" = "$record" ]; then
        emit '' "$record"
      else
        emit "$epoch" "${record#"$epoch"$'\t'}"
      fi
    done
    ;;
esac
