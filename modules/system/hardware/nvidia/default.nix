{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dots.system.hardware.nvidia;

  driverPackage =
    if cfg.package != null then
      cfg.package
    else if cfg.driverVersion != null then
      pkgs.linuxPackages.nvidiaPackages.mkDriver {
        version = cfg.driverVersion;
        sha256_64bit = cfg.driverSha256;
        useSettings = false;
        usePersistenced = false;
      }
    else
      config.boot.kernelPackages.nvidiaPackages.stable;
in
{
  options.dots.system.hardware.nvidia = {
    enable = lib.mkEnableOption "NVIDIA userspace and container support";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        NVIDIA driver package. Takes precedence over `driverVersion`.
        When running in an LXC container, this is the userspace driver, and its
        version must match the kernel driver on the Proxmox host.
      '';
    };

    driverVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "610.57.04";
      description = ''
        NVIDIA userspace driver version to fetch with
        `nvidiaPackages.mkDriver`. Use this when the host driver is newer than
        nixpkgs' stable package.
      '';
    };

    driverSha256 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SRI hash of the NVIDIA `.run` file for `driverVersion`.";
    };

    containerToolkit = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the NVIDIA container toolkit for Docker/Podman.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.driverVersion == null) == (cfg.driverSha256 == null);
        message = "dots.system.hardware.nvidia: set both driverVersion and driverSha256, or neither.";
      }
      {
        assertion = cfg.package == null || cfg.driverVersion == null;
        message = "dots.system.hardware.nvidia: package and driverVersion are mutually exclusive.";
      }
    ];

    nixpkgs.config = {
      allowUnfree = true;
      nvidia.acceptLicense = true;
    };

    hardware = {
      graphics = {
        enable = true;
        extraPackages = [ driverPackage ];
      };

      nvidia.package = driverPackage;

      nvidia-container-toolkit = lib.mkIf cfg.containerToolkit {
        enable = true;
        suppressNvidiaDriverAssertion = true;
      };
    };

    environment.systemPackages = [ driverPackage ];
  };
}
