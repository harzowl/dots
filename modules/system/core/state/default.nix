{ config, lib, ... }:
{
  options.dots.system.stateVersion = lib.mkOption {
    type = lib.types.str;
    default = "26.05";
    description = "NixOS state version, wired into `system.stateVersion`.";
  };

  config.system.stateVersion = lib.mkDefault config.dots.system.stateVersion;
}
