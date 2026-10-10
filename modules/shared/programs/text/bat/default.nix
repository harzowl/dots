# bat, defined once. home-manager ships `programs.bat` (its config file lands at
# `~/.config/bat/config`); the system target installs the package.
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
  mkShellAlias = import ../../../../../lib/mkShellAlias.nix;
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "text"
    "bat"
  ];
  description = "bat (a cat clone with syntax highlighting)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.bat;
        description = "The bat package to install.";
      };

      config = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "bat flags written to its config (`programs.bat.config` on the home target).";
      };

      aliasCat = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Define `cat` as an alias for `bat` in every shell.";
      };
    };

  home =
    args: cfg:
    args.lib.mkMerge [
      {
        programs.bat = {
          enable = true;
          inherit (cfg) package config;
        };
      }
      (args.lib.mkIf cfg.aliasCat (mkShellAlias { aliases = { cat = "bat"; }; } args))
    ];

  system =
    args: cfg:
    args.lib.mkMerge [
      { environment.systemPackages = [ cfg.package ]; }
      (args.lib.mkIf cfg.aliasCat (mkShellAlias { aliases = { cat = "bat"; }; } args))
    ];
}
