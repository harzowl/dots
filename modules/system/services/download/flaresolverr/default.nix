let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "flaresolverr";
    image = "ghcr.io/flaresolverr/flaresolverr:latest";
    ports = [ "8191:8191" ];
    openFirewall = true;
    extraOptions = [ "--shm-size=1g" ];
    settings = {
      logLevel = "info";
    };
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "flaresolverr"
  ];
  description = "FlareSolverr proxy for Prowlarr/Jackett (OCI container)";

  options =
    { lib, ... }:
    mkDockerService.options { inherit lib defaults; };

  toConfig =
    args: cfg:
    mkDockerService.config {
      spec = cfg;
      inherit defaults;
    } args;
}
