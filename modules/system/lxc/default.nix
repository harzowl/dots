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
  # proxmox-lxc.nix declares its own `proxmoxLXC.enable` (default true) and gates
  # ALL of its config behind it, so it is safe to import unconditionally and
  # disable via config. A conditional import (lib.mkIf ... path) is not
  # supported by the module system: mkIf-wrapped imports whose content is a bare
  # path/string evaluate to a non-attrset config and fail the top-level config
  # check in lib/modules.nix.
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  options.dots.system.lxc = {
    enable = lib.mkEnableOption "Proxmox LXC container support";

    manageNetwork = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Let NixOS manage the network configuration.";
    };

    disableSandbox = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable the Nix sandbox (required inside LXC).";
    };
  };

  config = lib.mkMerge [
    # Keep the proxmox module inert when dots' lxc switch is off (it defaults to
    # enabled on its own). mkDefault so users can still force it.
    { proxmoxLXC.enable = lib.mkDefault cfg.enable; }

    (lib.mkIf cfg.enable {
      nix.settings.sandbox = lib.mkDefault (!cfg.disableSandbox);
      proxmoxLXC.manageNetwork = lib.mkDefault cfg.manageNetwork;
    })
  ];
}
