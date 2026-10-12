# Feishin — a web client for Navidrome / Subsonic servers, run from the
# `ghcr.io/jeffvli/feishin` image. It is a pure client-side SPA: all settings and
# credentials live in the browser, so it has no volumes and holds no server state.
# It listens on :9180.
#
# Published on the host **loopback only** and with `openFirewall = false`, so the
# front proxy reaches it there and nothing else can. It is served behind the
# Keycloak gate; the browser session is seeded by the edge (which answers
# `/settings.js` itself), so no `SERVER_*` environment is set here.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "feishin";
    image = "ghcr.io/jeffvli/feishin:latest";
    ports = [ "127.0.0.1:9180:9180" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "music"
    "feishin"
  ];
  description = "Feishin music web client (OCI container)";

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
