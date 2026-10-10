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
    ports = [ 8080 ];
    settings = {
      # The fork disables them by default; turn the (patched) ones back on.
      googleDefault = "1";
      duckduckgoDefault = "1";
      imageProxy = "1";
    };
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
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
