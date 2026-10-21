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

  # The image treats these env vars as presence flags, so "0" or "false" would
  # still enable the engine.
  enabled = flag: if flag then "1" else "";
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

      instanceName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name shown in the UI; the image's default applies when null.";
      };

      baseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public URL of the instance; the image's default applies when null.";
      };

      defaultLang = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Default search language; the image's default applies when null.";
      };

      imageProxy = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Proxy result thumbnails through the instance.";
      };

      engines = lib.mkOption {
        type = lib.types.submodule {
          options = {
            google = lib.mkOption {
              type = lib.types.submodule {
                options = {
                  enable = lib.mkEnableOption "the Google engine";
                  mode = lib.mkOption {
                    type = lib.types.enum [
                      "cse"
                      "scraper"
                    ];
                    default = "cse";
                    description = "`cse` uses Google's CSE endpoint; `scraper` uses the HTML scraper, which Google currently blocks.";
                  };
                };
              };
              default = { };
            };

            bing.enable = lib.mkEnableOption "the Bing engine";
            duckduckgo.enable = lib.mkEnableOption "the DuckDuckGo engine";
            wikipedia.enable = lib.mkEnableOption "the Wikipedia engine";
            wikidata.enable = lib.mkEnableOption "the Wikidata engine";
          };
        };
        default = { };
        description = "Search engines enabled by default.";
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
      typedSettings =
        lib.optionalAttrs (cfg.instanceName != null) { name = cfg.instanceName; }
        // lib.optionalAttrs (cfg.baseUrl != null) { inherit (cfg) baseUrl; }
        // lib.optionalAttrs (cfg.defaultLang != null) { searchDefaultLang = cfg.defaultLang; }
        // {
          imageProxy = enabled cfg.imageProxy;
          googleDefault = enabled (cfg.engines.google.enable && cfg.engines.google.mode == "scraper");
          googleCseDefault = enabled (cfg.engines.google.enable && cfg.engines.google.mode == "cse");
          bingDefault = enabled cfg.engines.bing.enable;
          duckduckgoDefault = enabled cfg.engines.duckduckgo.enable;
          wikipediaDefault = enabled cfg.engines.wikipedia.enable;
          wikidataDefault = enabled cfg.engines.wikidata.enable;
        };
    in
    (mkDockerService.config {
      spec = cfg // {
        settings = cfg.settings // typedSettings;
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
