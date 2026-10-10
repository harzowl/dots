let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;

  # Engines bind-mounted over the image's: the fork ships upstream's, which are
  # broken (Google's dead `/wml` endpoint; DuckDuckGo's challenged `html`).
  engines = {
    duckduckgo = ./engines/duckduckgo.py;
    google = ./engines/google.py;
  };

  defaults = {
    name = "searxng";
    image = "ghcr.io/privau/searxng:latest";
    # The image hardcodes 8080; publish it as 3080 (the port `edge` proxies to).
    ports = [ "3080:8080" ];
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "search"
    "searxng"
  ];
  description = "SearXNG (priv.au fork) as an OCI container";

  options =
    { lib, ... }:
    mkDockerService.options { inherit lib defaults; };

  toConfig =
    args: cfg:
    let
      lib = args.lib;
      engineMounts = lib.mapAttrsToList (
        name: path: "${path}:/usr/local/searxng/searx/engines/${name}.py:ro"
      ) engines;
    in
    (mkDockerService.config {
      spec = cfg // {
        volumes = cfg.volumes ++ engineMounts;
      };
      inherit defaults;
    }) args;
}
