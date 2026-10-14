# fzf — a command-line fuzzy finder. home-manager ships `programs.fzf`, so the
# home target uses it (with its key bindings); the system target just installs
# the package.
{
  target,
  root ? [
    "dots"
    target
  ],
}:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "shell"
    "fzf"
  ];
  description = "fzf (a command-line fuzzy finder)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.fzf;
        description = "The fzf package to use.";
      };

      replaceNativeSearch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install fzf's key bindings (Ctrl-R history, Ctrl-T files, Alt-C cd)
          in place of each shell's native ones. When `false`, fzf is installed
          and configured but its key bindings are not installed.
        '';
      };

      defaultOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra command line options given to fzf by default (forwarded to `programs.fzf.defaultOptions`).";
      };

      defaultCommand = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The command fzf runs as its default source (forwarded to `programs.fzf.defaultCommand`).";
      };
    };

  home = args: cfg: {
    programs.fzf = {
      enable = true;
      inherit (cfg)
        package
        defaultCommand
        defaultOptions
        ;
      enableFishIntegration = cfg.replaceNativeSearch;
      enableBashIntegration = cfg.replaceNativeSearch;
      enableZshIntegration = cfg.replaceNativeSearch;
    };
  };

  system = args: cfg: { environment.systemPackages = [ cfg.package ]; };
}
