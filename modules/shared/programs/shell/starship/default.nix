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
      base0A = "3";
      base0B = "2";
      base0C = "6";
      base0D = "4";
      base0E = "5";
      base0F = "17";
    };

    format =
      "[](fg:base08)"
      + "$os"
      + "$username"
      + "[](bg:base09 fg:base08)"
      + "$directory"
      + "[](bg:base0A fg:base09)"
      + "$git_branch"
      + "$git_status"
      + "[](bg:base0B fg:base0A)"
      + "$c"
      + "$rust"
      + "$golang"
      + "$nodejs"
      + "$php"
      + "$java"
      + "$kotlin"
      + "$haskell"
      + "$python"
      + "[](fg:base0B bg:base0C)"
      + "$conda"
      + "[](fg:base0C bg:base0D)"
      + "$time"
      + "[ ](fg:base0D)"
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
      style = "bg:base0A";
      format = "[[ $symbol $branch ](fg:base01 bg:base0A)]($style)";
    };

    git_status = {
      style = "bg:base0A";
      format = "[[($all_status$ahead_behind )](fg:base01 bg:base0A)]($style)";
    };

    nodejs = {
      symbol = "";
      style = "bg:base0B";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0B)]($style)";
    };

    c = {
      symbol = " ";
      style = "bg:base0B";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0B)]($style)";
    };

    rust = {
      symbol = "";
      style = "bg:base0B";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0B)]($style)";
    };

    golang = {
      symbol = "";
      style = "bg:base0B";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0B)]($style)";
    };

    php = {
      symbol = "";
      style = "bg:base0B";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0B)]($style)";
    };

    java = {
      symbol = " ";
      style = "bg:base0B";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0B)]($style)";
    };

    kotlin = {
      symbol = "";
      style = "bg:base0B";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0B)]($style)";
    };

    haskell = {
      symbol = "";
      style = "bg:base0B";
      format = "[[ $symbol( $version) ](fg:base01 bg:base0B)]($style)";
    };

    python = {
      symbol = "";
      style = "bg:base0B";
      format = "[[ $symbol( $version)(\(#$virtualenv\)) ](fg:base01 bg:base0B)]($style)";
    };

    docker_context = {
      symbol = "";
      style = "bg:base0C";
      format = "[[ $symbol( $context) ](fg:base01 bg:base0C)]($style)";
    };

    conda = {
      symbol = "  ";
      style = "fg:base01 bg:base0C";
      format = "[$symbol$environment ]($style)";
      ignore_base = false;
    };

    time = {
      disabled = false;
      time_format = "%R";
      style = "bg:base0D";
      format = "[[  $time ](fg:base01 bg:base0D)]($style)";
    };

    line_break.disabled = false;

    character = {
      disabled = false;
      success_symbol = "[❯](bold fg:base0B)";
      error_symbol = "[❯](bold fg:base08)";
      vimcmd_symbol = "[❮](bold fg:base0B)";
      vimcmd_replace_one_symbol = "[❮](bold fg:base0D)";
      vimcmd_replace_symbol = "[❮](bold fg:base0D)";
      vimcmd_visual_symbol = "[❮](bold fg:base0A)";
    };

    cmd_duration = {
      show_milliseconds = true;
      format = " in $duration ";
      style = "bg:base0D";
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
