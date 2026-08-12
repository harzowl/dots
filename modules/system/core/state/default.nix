{ config, lib, ... }:
{
  options.dots.system.stateVersion = lib.mkOption {
    type = lib.types.str;
    default = "26.05";
    description = "NixOS state version, wired into `system.stateVersion`.";
  };

  # mkDefault: flakes can still pin system.stateVersion directly if they want to
  # diverge from dots' nixpkgs branch (dots pins nixos-26.05).
  config.system.stateVersion = lib.mkDefault config.dots.system.stateVersion;
}
