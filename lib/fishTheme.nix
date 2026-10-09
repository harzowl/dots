# dots fish color theme, written to `conf.d/dots-theme.fish` by both the system
# and home fish modules. Colors use ANSI names so the theme follows the
# terminal's base16 palette dynamically — no stylix and no hardcoded hex.
#
# It is loaded from conf.d (before config.fish), so anything a user sets through
# `programs.fish` settings (interactiveShellInit etc.) still overrides it.
''
  # dots fish theme (terminal-dynamic, base16 via ANSI names)
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
''
