{
  config,
  lib,
  ...
}:
let
  cfg = config.dots.system.docker;
in
{
  options.dots.system.docker.gpu = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.enum [
        "nvidia"
        "intel"
        "amd"
      ]
    );
    default = null;
    description = "GPU mode for Docker containers on this host.";
  };

  config = lib.mkIf (cfg.gpu == "nvidia") {
    hardware.nvidia-container-toolkit.enable = lib.mkDefault true;
  };
}
