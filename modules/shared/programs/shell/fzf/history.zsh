# Replaces fzf's own Ctrl-R widget: it keeps fzf's function name and rebinds
# ^R, so fzf's bindings resolve to this one. zsh's timestamped history lives in
# the extended history file, so the shared formatter reads that; only the
# command is inserted.
fzf-history-widget() {
  setopt localoptions no_aliases
  local selected
  selected=$(
    "@HISTORY_DATE@" --zsh "${HISTFILE:-$HOME/.zsh_history}" \
      | fzf --height=40% --min-height=20+ --bind=ctrl-z:ignore \
          --read0 --no-multi-line --tabstop=4 \
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
