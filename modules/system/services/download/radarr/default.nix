# Radarr — movie manager (LinuxServer image), :7878. Only the service's own
# identity lives here; the consumer supplies volumes, the environment
# (TZ/PUID/PGID) and how it is fronted.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "radarr";
    image = "lscr.io/linuxserver/radarr:latest";
    ports = [ "127.0.0.1:7878:7878" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "radarr"
  ];
  description = "Radarr movie manager (OCI container)";

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
