let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;

  engines = {
    duckduckgo = ./engines/duckduckgo.py;
    google = ./engines/google.py;
  };

  customCssScript = ./custom-css.sh;

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
    (mkDockerService.options { inherit lib defaults; })
    // {
      customCss = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "CSS appended to the `simple` theme's stylesheet at container start.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib;
      engineMounts = lib.mapAttrsToList (
        name: path: "${path}:/usr/local/searxng/searx/engines/${name}.py:ro"
      ) engines;
      customCssMounts = lib.optionals (cfg.customCss != null) [
        "${cfg.customCss}:/usr/local/searxng/custom.css:ro"
        "${customCssScript}:/usr/local/bin/searxng-custom-css:ro"
      ];
    in
    (mkDockerService.config {
      spec = cfg // {
        volumes = cfg.volumes ++ engineMounts ++ customCssMounts;
        cmd =
          if cfg.customCss != null then
            [
              "/bin/sh"
              "/usr/local/bin/searxng-custom-css"
            ]
          else
            cfg.cmd;
      };
      inherit defaults;
    })
      args;
}
