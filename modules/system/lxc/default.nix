{
  config,
  lib,
  modulesPath,
  ...
}:
let
  cfg = config.dots.system.lxc;
in
{
  imports = [ (lib.mkIf cfg.enable (modulesPath + "/virtualisation/proxmox-lxc.nix")) ];

  options.dots.system.lxc = {
    enable = lib.mkEnableOption "Proxmox LXC container support";

    manageNetwork = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the container manages its own network.";
    };

    sandbox = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable the nix sandbox (required inside LXC).";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings.sandbox = lib.mkDefault cfg.sandbox;
    proxmoxLXC.manageNetwork = lib.mkDefault cfg.manageNetwork;
  };
}
