let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;

  # Patches shipped with this module, keyed by the name used under `patches`.
  # Enable one with `dots.system.services.searxng.patches.<name>.enable = true;`.
  patchFiles = {
    google = ./patches/google.patch;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "searxng"
  ];
  description = "SearXNG meta search engine";

  options =
    { config, lib, pkgs, ... }:
    let
      # nixpkgs-unstable: the current (curl_cffi) SearXNG engine.
      unstable = config._module.args.nixpkgsUnstable;
    in
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.searxng;
        description = "The SearXNG package to use.";
      };

      patches = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.enable = lib.mkEnableOption "this SearXNG source patch";
          }
        );
        default = { };
        description = ''
          SearXNG source patches shipped by dots, enabled by name
          (`patches.<name>.enable`). Known patches:
          ${lib.concatStringsSep ", " (lib.attrNames patchFiles)}.
        '';
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
    { lib, ... }:
    cfg:
    {
      assertions = [
        {
          assertion = lib.all (name: patchFiles ? ${name}) (lib.attrNames cfg.patches);
          message = "dots.system.services.searxng.patches: unknown patch (known: ${lib.concatStringsSep ", " (lib.attrNames patchFiles)}).";
        }
      ];

      services.searx = {
        enable = true;
        package = cfg.package.overrideAttrs (old: {
          patches =
            (old.patches or [ ])
            ++ lib.mapAttrsToList (name: _: patchFiles.${name}) (
              lib.filterAttrs (name: p: p.enable && patchFiles ? ${name}) cfg.patches
            );
        });
        inherit (cfg)
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
