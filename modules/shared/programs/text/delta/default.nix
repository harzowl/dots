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
    "text"
    "delta"
  ];
  description = "delta (a syntax-highlighting pager for git and diff output)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.delta;
        description = "The delta package to install.";
      };

      gitIntegration = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Make delta the default git pager and interactive diff filter.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {
          navigate = true;
          line-numbers = true;
        };
        description = "Delta settings written to the `[delta]` git config section.";
      };
    };

  home =
    args: cfg:
    let
      inherit (args) lib;
      gitConfig = {
        core.pager = "${cfg.package}/bin/delta";
        interactive.diffFilter = "${cfg.package}/bin/delta --color-only";
        delta = cfg.settings;
      };
    in
    lib.mkMerge [
      { home.packages = [ cfg.package ]; }
      (lib.mkIf cfg.gitIntegration {
        programs.git = {
          enable = true;
          settings = gitConfig;
        };
      })
    ];

  system =
    args: cfg:
    let
      inherit (args) lib;
      gitConfig = {
        core.pager = "${cfg.package}/bin/delta";
        interactive.diffFilter = "${cfg.package}/bin/delta --color-only";
        delta = cfg.settings;
      };
    in
    lib.mkMerge [
      { environment.systemPackages = [ cfg.package ]; }
      (lib.mkIf cfg.gitIntegration {
        environment.etc."gitconfig".text = lib.generators.toGitINI gitConfig;
      })
    ];
}
