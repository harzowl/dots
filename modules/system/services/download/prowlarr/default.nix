# Prowlarr — indexer manager for the *arr stack (LinuxServer image), :9696.
# Only the service's own identity lives here; the consumer supplies volumes,
# the environment (TZ/PUID/PGID) and how it is fronted.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "prowlarr";
    image = "lscr.io/linuxserver/prowlarr:latest";
    ports = [ "127.0.0.1:9696:9696" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "prowlarr"
  ];
  description = "Prowlarr indexer manager (OCI container)";

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
