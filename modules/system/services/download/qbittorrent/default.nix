# qBittorrent — torrent client (LinuxServer image); its WebUI is :8080, served
# with vuetorrent as the alternate WebUI. Only the service's own identity lives
# here; the consumer supplies volumes, the environment (TZ/PUID/PGID) and how
# it is fronted.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "qbittorrent";
    image = "lscr.io/linuxserver/qbittorrent:latest";
    ports = [ "127.0.0.1:8080:8080" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "qbittorrent"
  ];
  description = "qBittorrent client (OCI container)";

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
