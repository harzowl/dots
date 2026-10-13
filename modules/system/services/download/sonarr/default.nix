# Sonarr — TV series manager (LinuxServer image), :8989. Only the service's own
# identity lives here; the consumer supplies volumes, the environment
# (TZ/PUID/PGID) and how it is fronted.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "sonarr";
    image = "lscr.io/linuxserver/sonarr:latest";
    ports = [ "127.0.0.1:8989:8989" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "sonarr"
  ];
  description = "Sonarr TV manager (OCI container)";

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
