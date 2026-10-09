# dots fish theme (terminal-dynamic, base16 via ANSI names). Written to
# conf.d/dots-theme.fish; loaded before config.fish, so anything set through
# `programs.fish` settings (e.g. interactiveShellInit) still overrides it.
set --global fish_color_normal normal
set --global fish_color_command green
set --global fish_color_param white
set --global fish_color_quote yellow
set --global fish_color_redirection cyan
set --global fish_color_end brblack
set --global fish_color_error red
set --global fish_color_comment brblack
set --global fish_color_operator blue
set --global fish_color_escape yellow
set --global fish_color_autosuggestion brblack
set --global fish_color_cwd green
set --global fish_color_cwd_root red
set --global fish_color_user brgreen
set --global fish_color_host normal
set --global fish_color_status red
set --global fish_color_cancel -r
set --global fish_color_history_current --bold
set --global fish_color_match --background=brblue
set --global fish_color_search_match bryellow --background=brblack
set --global fish_color_selection white --bold --background=brblack
set --global fish_color_valid_path --underline
