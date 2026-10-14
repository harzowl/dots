# Replaces fzf's own Ctrl-R widget: it keeps fzf's function name and rebinds
# ^R, while atuin stays the history store. The shared formatter dates and colours
# each row, and only the command is inserted.
fzf-history-widget() {
  setopt localoptions no_aliases
  local selected
  selected=$(
    atuin history list --print0 -f '{time}\t{command}' \
      | "@HISTORY_DATE@" \
      | fzf --height=40% --min-height=20+ --bind=ctrl-z:ignore \
          --read0 --no-multi-line --tabstop=4 --ansi \
          --delimiter=$'\t' --accept-nth=2.. --multi \
          --query="${LBUFFER}"
  ) || return
  [ -n "$selected" ] || return
  LBUFFER="${selected}"
  zle reset-prompt
}

zle -N fzf-history-widget
bindkey -M emacs '^R' fzf-history-widget
bindkey -M viins '^R' fzf-history-widget
bindkey -M vicmd '^R' fzf-history-widget
