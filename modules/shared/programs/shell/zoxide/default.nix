# zoxide — a smarter `cd` that learns the directories you visit. home-manager
# ships `programs.zoxide`, so the home target uses it (with shell integration);
# the system target just installs the package.
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "shell"
    "zoxide"
  ];
  description = "zoxide (a smarter cd)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.zoxide;
        description = "The zoxide package to use.";
      };

      options = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra `zoxide init` args (forwarded to `programs.zoxide.options`).";
      };
    };

  home =
    args: cfg:
    {
      programs.zoxide = {
        enable = true;
        inherit (cfg) package options;
        enableFishIntegration = true;
        enableBashIntegration = true;
        enableZshIntegration = true;
        enableNushellIntegration = true;
      };
    };

  system = args: cfg: { environment.systemPackages = [ cfg.package ]; };
}
