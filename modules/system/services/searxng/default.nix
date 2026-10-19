let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;

  engines = {
    duckduckgo = ./engines/duckduckgo.py;
    google = ./engines/google.py;
  };

  defaults = {
    name = "searxng";
    image = "ghcr.io/privau/searxng:latest";
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
      inherit (args) lib;
      engineMounts = lib.mapAttrsToList (
        name: path: "${path}:/usr/local/searxng/searx/engines/${name}.py:ro"
      ) engines;
    in
    (mkDockerService.config {
      spec = cfg // {
        volumes = cfg.volumes ++ engineMounts;
      };
      inherit defaults;
    })
      args;
}
