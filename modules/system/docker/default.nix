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

  config = lib.mkMerge [
    {
      warnings =
        lib.optional (cfg.gpu == "nvidia" && !config.dots.system.hardware.nvidia.enable)
          "dots.system.docker.gpu = \"nvidia\" but dots.system.hardware.nvidia.enable is false; the NVIDIA container toolkit is not enabled.";
    }
    (lib.mkIf
      (
        cfg.gpu == "nvidia"
        && config.dots.system.hardware.nvidia.enable
        && config.dots.system.hardware.nvidia.containerToolkit
      )
      {
        hardware.nvidia-container-toolkit.enable = lib.mkDefault true;
      }
    )
  ];
}
