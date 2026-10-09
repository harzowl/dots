# starship, defined once. Imported by both `modules/system` and `modules/home`
# (each passing its target), so the same definition surfaces as
# `dots.system.programs.shell.starship` and
# `dots.home.programs.shell.starship`.
#
# The default prompt is ported from nix-dotfiles but made terminal-dynamic: every
# color references the `base16` palette below, which maps base16 slots onto the
# terminal's own base16 ANSI palette. No stylix and no hardcoded hex, so changing
# the terminal theme changes the prompt. Values use the standard base16-shell
# 256-color indices (0-21).
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;

  defaults = {
    palette = "base16";
    palettes.base16 = {
      base00 = "0";
      base01 = "18";
      base02 = "19";
      base03 = "8";
      base04 = "20";
      base05 = "7";
      base06 = "21";
      base07 = "15";
      base08 = "1";
      base09 = "16";
      base0a = "3";
      base0b = "2";
      base0c = "6";
      base0d = "4";
      base0e = "5";
      base0f = "17";
    };

    format =
      "[](fg:base08)"
      + "$os"
      + "$username"
      + "[](bg:base09 fg:base08)"
      + "$directory"
      + "[](bg:base0a fg:base09)"
      + "$git_branch"
      + "$git_status"
      + "[](bg:base0b fg:base0a)"
      + "$c"
      + "$rust"
      + "$golang"
      + "$nodejs"
      + "$php"
      + "$java"
      + "$kotlin"
      + "$haskell"
      + "$python"
      + "[](fg:base0b bg:base0c)"
      + "$conda"
      + "[](fg:base0c bg:base0d)"
      + "$time"
      + "[ ](fg:base0d)"
      + "$cmd_duration"
      + "$line_break"
      + "$character";

    os = {
      disabled = false;
      style = "bg:base08 fg:base01";

      symbols = {
        Windows = "";
        Ubuntu = "󰕈";
        SUSE = "";
        Raspbian = "󰐿";
        Mint = "󰣭";
        Macos = "󰀵";
        Manjaro = "";
        Linux = "󰌽";
        Gentoo = "󰣨";
        Fedora = "󰣛";
        Alpine = "";
        Amazon = "";
        Android = "";
        Arch = "󰣇";
        Artix = "󰣇";
        CentOS = "";
        Debian = "󰣚";
        Redhat = "󱄛";
        RedHatEnterprise = "󱄛";
        NixOS = "";
      };
    };

    username = {
      show_always = true;
      style_user = "bg:base08 fg:base01";
      style_root = "bg:base08 fg:base01";
      format = "[ $user]($style)";
    };

    directory = {
      style = "bg:base09 fg:base01";
      format = "[ $path ]($style)";
      truncation_length = 2;
      truncation_symbol = "…/";

      substitutions = {
        "Documents" = "󰈙 ";
        "Downloads" = " ";
        "Music" = "󰝚 ";
        "Pictures" = " ";
        "Developer" = "󰲋 ";
      };
    };

    git_branch = {
      symbol = "";
      style = "bg:base0a";
      format = "[[ $symbol $branch ](fg:base01 bg:base0a)]($style)";
    };

    git_status = {
      style = "bg:base0a";
      format = "[[($all_status$ahead_behind )](fg:base01 bg:base0a)]($style)";
    };

    nodejs = {
      symbol = "";
      style = "bg:base0b";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0b)]($style)";
    };

    c = {
      symbol = " ";
      style = "bg:base0b";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0b)]($style)";
    };

    rust = {
      symbol = "";
      style = "bg:base0b";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0b)]($style)";
    };

    golang = {
      symbol = "";
      style = "bg:base0b";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0b)]($style)";
    };

    php = {
      symbol = "";
      style = "bg:base0b";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0b)]($style)";
    };

    java = {
      symbol = " ";
      style = "bg:base0b";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0b)]($style)";
    };

    kotlin = {
      symbol = "";
      style = "bg:base0b";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0b)]($style)";
    };

    haskell = {
      symbol = "";
      style = "bg:base0b";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0b)]($style)";
    };

    python = {
      symbol = "";
      style = "bg:base0b";
      format = "[[ $symbol( $version)(\(#$virtualenv\)) ](fg:base01 bg:base0b)]($style)";
    };

    docker_context = {
      symbol = "";
      style = "bg:base0c";
      format = "[[ $symbol( $context) ](fg:base01 bg:base0c)]($style)";
    };

    conda = {
      symbol = "  ";
      style = "fg:base01 bg:base0c";
      format = "[$symbol$environment ]($style)";
      ignore_base = false;
    };

    time = {
      disabled = false;
      time_format = "%R";
      style = "bg:base0d";
      format = "[[  $time ](fg:base01 bg:base0d)]($style)";
    };

    line_break.disabled = false;

    character = {
      disabled = false;
      success_symbol = "[❯](bold fg:base0b)";
      error_symbol = "[❯](bold fg:base08)";
      vimcmd_symbol = "[❮](bold fg:base0b)";
      vimcmd_replace_one_symbol = "[❮](bold fg:base0d)";
      vimcmd_replace_symbol = "[❮](bold fg:base0d)";
      vimcmd_visual_symbol = "[❮](bold fg:base0a)";
    };

    cmd_duration = {
      show_milliseconds = true;
      format = " in $duration ";
      style = "bg:base0d";
      disabled = false;
    };
    };
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "shell"
    "starship"
  ];
  description = "Starship shell prompt";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.starship;
        description = "The starship package to use.";
      };

      settings = lib.mkOption {
        type = (pkgs.formats.toml { }).type;
        default = { };
        description = "Starship configuration, deep-merged over the built-in terminal-dynamic base16 defaults, forwarded to `programs.starship.settings`.";
      };
    };

  home =
    args: cfg:
    {
      programs.starship = {
        enable = true;
        inherit (cfg) package;
        settings = args.lib.recursiveUpdate defaults cfg.settings;
      };
    };

  system =
    args: cfg:
    {
      programs.starship = {
        enable = true;
        inherit (cfg) package;
        settings = args.lib.recursiveUpdate defaults cfg.settings;
      };
    };
}
