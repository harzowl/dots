{
  hostType,
  lib,
  modulesPath,
  ...
}:
{
  imports = lib.optional (hostType == "digitalOcean") (
    modulesPath + "/virtualisation/digital-ocean-config.nix"
  );

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
    dots.system.lxc.enable = lib.mkIf (hostType == "lxc") (lib.mkDefault true);
  };
}
