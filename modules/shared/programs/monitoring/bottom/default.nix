# bottom, defined once. Imported by both `modules/system` and `modules/home`
# (each passing its target), so the same definition surfaces as
# `dots.system.programs.monitoring.bottom` and
# `dots.home.programs.monitoring.bottom` — the end-user configures whichever
# namespace they want.
#
#   system target -> install the package system-wide
#   home target   -> manage `programs.bottom` (package + settings) per user
{ target }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
  mkShellAlias = import ../../../../../lib/mkShellAlias.nix;
  htopAlias = {
    htop = "btm -b";
  };
in
mkSharedProgram {
  inherit target;
  optionPath = [
    "programs"
    "monitoring"
    "bottom"
  ];
  description = "Bottom system monitor";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.bottom;
        description = "The bottom package to install.";
      };

      settings = lib.mkOption {
        type = (pkgs.formats.toml { }).type;
        default = { };
        description = "bottom configuration, forwarded to `programs.bottom.settings` on the home target. Per-user settings shadow the system install.";
      };

      aliasHtop = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Define `htop` as an alias for `btm -b` in every shell.";
      };
    };

  home =
    args: cfg:
    args.lib.mkMerge [
      {
        programs.bottom = {
          enable = true;
          inherit (cfg) package settings;
        };
      }
      (args.lib.mkIf cfg.aliasHtop (mkShellAlias { aliases = htopAlias; } args))
    ];

  system =
    args: cfg:
    args.lib.mkMerge [
      { environment.systemPackages = [ cfg.package ]; }
      (args.lib.mkIf cfg.aliasHtop (mkShellAlias { aliases = htopAlias; } args))
    ];
}
