# Replaces fzf's own Ctrl-R widget: it keeps fzf's function name and rebinds
# ^R, while atuin stays the history store (the module keeps its recording hooks
# and only its own Ctrl-R binding off). The shared formatter dates and colours
# each row, and only the command is inserted.
function fzf-history-widget -d "Show atuin history with a local date column"
    set -l command_line (commandline)
    set -l current_line (commandline -L)
    set -l total_lines (count $command_line)
    set -l buf $command_line[$current_line]

    # A failed atuin exits non-zero; its error must not reach fzf as history.
    set -l data (mktemp)
    atuin history list --print0 -f '{time}\t{command}' >$data 2>/dev/null
    or begin
        rm -f $data
        return
    end

    set -l fzf_args --height=40% --min-height=20+ --bind=ctrl-z:ignore \
        --read0 --print0 --no-multi-line --tabstop=4 --ansi \
        --delimiter=\t --accept-nth=2.. --multi
    test -n "$buf"; and set -a fzf_args --query="$buf"

    set -l result ("@HISTORY_DATE@" <$data | fzf $fzf_args | string split0)
    rm -f $data

    if test (count $result) -gt 0
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
