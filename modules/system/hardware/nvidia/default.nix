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
    else if cfg.driver != null then
      let
        repoPath = if cfg.driver.repo == "tesla" then "tesla" else "XFree86/Linux-x86_64";
      in
      pkgs.linuxPackages.nvidiaPackages.mkDriver {
        version = cfg.driver.version;
        sha256_64bit = cfg.driver.sha256;
        useSettings = false;
        usePersistenced = false;
        url = "https://us.download.nvidia.com/${repoPath}/${cfg.driver.version}/NVIDIA-Linux-x86_64-${cfg.driver.version}.run";
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
        NVIDIA driver package. Mutually exclusive with `driver`.
        When running in an LXC container, this is the userspace driver, and its
        version must match the kernel driver on the Proxmox host.
      '';
    };

    driver = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            version = lib.mkOption {
              type = lib.types.str;
              example = "615.71.10";
              description = "NVIDIA userspace driver version to fetch with `nvidiaPackages.mkDriver`.";
            };

            sha256 = lib.mkOption {
              type = lib.types.str;
              description = "SRI hash of the NVIDIA `.run` file for `version`.";
            };

            repo = lib.mkOption {
              type = lib.types.enum [
                "XFree86"
                "tesla"
              ];
              default = "XFree86";
              description = "NVIDIA download channel: `XFree86` for GeForce/Quadro, `tesla` for data-centre releases.";
            };
          };
        }
      );
      default = null;
      description = "NVIDIA userspace driver to fetch with `nvidiaPackages.mkDriver`.";
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
        assertion = cfg.package == null || cfg.driver == null;
        message = "dots.system.hardware.nvidia: package and driver are mutually exclusive.";
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
