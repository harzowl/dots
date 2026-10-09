{ config, lib, ... }:
let
  # Re-root the shared home programs directly under each user, so a user's
  # config reads `dots.home.users.<name>.programs.monitoring.bottom`.
  homePrograms = import ../../shared {
    target = "home";
    root = [ ];
  };

  # Provides the `home.stateVersion` default (dots.home.stateVersion).
  homeCore = import ../../home/core;
in
{
  options.dots.home.users = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = ''
      Per-user Home Manager configuration. Each entry is wired to
      `home-manager.users.<name>`, with the dots home tree rooted directly under
      the user, e.g. `dots.home.users.<name>.programs.monitoring.bottom.enable`.
    '';
  };

  config.home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    users = lib.mapAttrs (
      _: userCfg:
      lib.mkMerge [
        { imports = [ homeCore homePrograms ]; }
        userCfg
      ]
    ) config.dots.home.users;
  };
}
