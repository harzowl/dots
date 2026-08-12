{ config, lib, ... }: {
  options.dots.home.stateVersion = lib.mkOption {
    type = lib.types.str;
    default = "26.05";
    description = "Home Manager state version, wired into `home.stateVersion`.";
  };

  # mkDefault: both the NixOS-module path and standalone homeConfigurations get
  # it; a flake can still override with home.stateVersion / dots.home.stateVersion.
  config.home.stateVersion = lib.mkDefault config.dots.home.stateVersion;
}
