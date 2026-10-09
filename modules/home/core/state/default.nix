{ root ? [ "dots" "home" ] }:
{ config, lib, ... }:
let
  path = root ++ [ "stateVersion" ];
in
{
  options = lib.setAttrByPath path (
    lib.mkOption {
      type = lib.types.str;
      default = "26.05";
      description = "Home Manager state version, wired into `home.stateVersion`.";
    }
  );

  # mkDefault: both the NixOS-module path and standalone homeConfigurations get
  # it; a flake can still override with home.stateVersion / dots.home.stateVersion.
  config.home.stateVersion = lib.mkDefault (lib.getAttrFromPath path config);
}
