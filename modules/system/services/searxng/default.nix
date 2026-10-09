let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "searxng"
  ];
  description = "SearXNG meta search engine";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.searxng;
        description = "The SearXNG package to use.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = ''
          SearXNG `settings.yml`, forwarded to `services.searx.settings`.
          At minimum `server.port` and `server.secret_key` are required
          (the latter may reference `$VAR` from `environmentFile`).
        '';
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Environment file for secrets referenced from `settings` (e.g.
          `server.secret_key = "$SEARX_SECRET_KEY"`). Forwarded to
          `services.searx.environmentFile`; keeps secrets out of the store.
        '';
      };

      redisCreateLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run a local Valkey/Redis for the rate limiter and cache (`services.searx.redisCreateLocally`).";
      };

      limiterSettings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Limiter settings, forwarded to `services.searx.limiterSettings`.";
      };

      faviconsSettings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Favicon settings, forwarded to `services.searx.faviconsSettings`.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Open the port declared in `settings.server.port` (`services.searx.openFirewall`).";
      };
    };

  toConfig =
    _: cfg:
    {
      services.searx = {
        enable = true;
        inherit (cfg)
          package
          settings
          environmentFile
          redisCreateLocally
          limiterSettings
          faviconsSettings
          openFirewall
          ;
      };
    };
}
