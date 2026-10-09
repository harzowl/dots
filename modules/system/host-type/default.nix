# Which platform the host runs on. Driven by the `hostType` *module argument*,
# not an option: `imports` is evaluated before `config`, so a platform module
# cannot be chosen by reading a `dots.system.*` option. It has NO default and
# MUST be passed via `specialArgs` — a module argument without `specialArgs`
# would be looked up in `_module.args`, which needs `config`, and reading
# `config` during evaluation then recurses. So a host does:
#
#   lib.nixosSystem {
#     specialArgs = { hostType = "lxc"; };
#     ...
#   }
#
#   "generic"      — bare metal / VM (pass this explicitly; nothing extra).
#   "lxc"          — Proxmox LXC guest; reuses ../lxc (`dots.system.lxc`).
#   "digitalOcean" — DigitalOcean image layout (GRUB to /dev/vda, cloud-init).
{ hostType, lib, modulesPath, ... }:
{
  imports = lib.optional (hostType == "digitalOcean")
    (modulesPath + "/virtualisation/digital-ocean-config.nix");

  options.dots.system.hostType = lib.mkOption {
    type = lib.types.enum [
      "generic"
      "lxc"
      "digitalOcean"
    ];
    default = hostType;
    readOnly = true;
    description = "Host platform, set via the `hostType` module argument.";
  };

  config = {
    # LXC support lives in ../lxc (already imported) and is gated by
    # `dots.system.lxc`; hostType only flips it on. DigitalOcean is a plain
    # import (above). mkDefault so a host can still force either.
    dots.system.lxc.enable = lib.mkIf (hostType == "lxc") (lib.mkDefault true);
  };
}
