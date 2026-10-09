# ripgrep, defined once. home-manager already ships `programs.ripgrep`, so the
# home target uses it for installation; `settings` go to ripgrep's native config
# file via RIPGREP_CONFIG_PATH (no wrapper). The system target installs the
# package and points the env var at the same config.
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "search"
    "ripgrep"
  ];
  description = "ripgrep (rg)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.ripgrep;
        description = "The ripgrep package to use.";
      };

      settings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extra ripgrep arguments, one per line of its config file. The file is
          pointed at by `RIPGREP_CONFIG_PATH`, so they apply to every `rg`
          invocation. For example `[ "--smart-case" "--hidden" ]`.
        '';
      };
    };

  home =
    args: cfg:
    args.lib.mkMerge [
      { programs.ripgrep = { enable = true; inherit (cfg) package; }; }
      (args.lib.mkIf (cfg.settings != [ ]) {
        home.sessionVariables.RIPGREP_CONFIG_PATH = args.pkgs.writeText "ripgreprc" (
          args.lib.concatStringsSep "\n" cfg.settings
        );
      })
    ];

  system =
    args: cfg:
    args.lib.mkMerge [
      { environment.systemPackages = [ cfg.package ]; }
      (args.lib.mkIf (cfg.settings != [ ]) {
        environment.variables.RIPGREP_CONFIG_PATH = args.pkgs.writeText "ripgreprc" (
          args.lib.concatStringsSep "\n" cfg.settings
        );
      })
    ];
}
