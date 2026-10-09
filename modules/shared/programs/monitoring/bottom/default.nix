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
    };

  home =
    _: cfg:
    {
      programs.bottom = {
        enable = true;
        inherit (cfg) package settings;
      };
    };

  system =
    _: cfg:
    {
      environment.systemPackages = [ cfg.package ];
    };
}
