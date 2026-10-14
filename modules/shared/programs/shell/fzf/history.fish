# Replaces fzf's own Ctrl-R widget: it keeps fzf's function name, so fzf's
# key bindings resolve to this one. Fish's `history` builtin is the
# authoritative reader (it decodes multi-line entries and merges sessions);
# `%s` emits each entry's epoch, which the shared formatter renders as a local
# date. Only the command is ever inserted into the command line.
function fzf-history-widget -d "Show command history with a local date column"
    set -l command_line (commandline)
    set -l current_line (commandline -L)
    set -l total_lines (count $command_line)
    set -l fzf_query (string escape -- $command_line[$current_line])

    test -z "$fish_private_mode"; and builtin history merge

    if set -l result (builtin history -z --show-time='%s%t' \
            | "@HISTORY_DATE@" \
            | fzf --height=40% --min-height=20+ --bind=ctrl-z:ignore \
                --read0 --print0 --no-multi-line --tabstop=4 \
                --delimiter=\t --accept-nth=2.. --multi \
                --query=$fzf_query | string split0)
        if test "$total_lines" -eq 1
            commandline -- $result
        else
            set -l a (math $current_line - 1)
            set -l b (math $current_line + 1)
            commandline -- $command_line[1..$a] $result
            commandline -a -- '' $command_line[$b..-1]
        end
    end

    commandline -f repaint
end

bind \cr fzf-history-widget
bind -M insert \cr fzf-history-widget
