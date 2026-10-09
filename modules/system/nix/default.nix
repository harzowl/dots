# Nix daemon / store housekeeping, opt-in per node.
{ config, lib, ... }:
let
  cfg = config.dots.system.nix;
in
{
  options.dots.system.nix = {
    gc = {
      enable = lib.mkEnableOption "periodic Nix store garbage collection";

      dates = lib.mkOption {
        type = lib.types.either lib.types.singleLineStr (lib.types.listOf lib.types.str);
        default = "weekly";
        description = "systemd calendar spec(s) for the GC timer, forwarded to `nix.gc.dates`.";
      };

      keepDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Delete generations older than this many days before collecting (`--delete-older-than <keepDays>d`).";
      };
    };

    autoOptimiseStore = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Hard-link identical files in the Nix store to save space (`nix.settings.auto-optimise-store`).";
    };

    experimentalFeatures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nix-command"
        "flakes"
      ];
      description = "Value of `nix.settings.experimental-features`. Defaults to `nix-command` and `flakes`.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.gc.enable {
      nix.gc = {
        automatic = true;
        inherit (cfg.gc) dates;
        options = "--delete-older-than ${toString cfg.gc.keepDays}d";
      };
    })

    (lib.mkIf cfg.autoOptimiseStore {
      nix.settings.auto-optimise-store = true;
    })

    (lib.mkIf (cfg.experimentalFeatures != [ ]) {
      nix.settings.experimental-features = cfg.experimentalFeatures;
    })
  ];
}
