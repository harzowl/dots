# Lidarr — music library manager (LinuxServer image), :8686. Only the service's
# own identity lives here; the consumer supplies volumes, the environment
# (TZ/PUID/PGID) and how it is fronted.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "lidarr";
    image = "lscr.io/linuxserver/lidarr:latest";
    ports = [ 8686 ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "lidarr"
  ];
  description = "Lidarr music manager (OCI container)";

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
