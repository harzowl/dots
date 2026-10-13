# Bazarr — subtitle manager for Sonarr/Radarr (LinuxServer image), :6767. Only
# the service's own identity lives here; the consumer supplies volumes, the
# environment (TZ/PUID/PGID) and how it is fronted.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "bazarr";
    image = "lscr.io/linuxserver/bazarr:latest";
    ports = [ "127.0.0.1:6767:6767" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "bazarr"
  ];
  description = "Bazarr subtitle manager (OCI container)";

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
