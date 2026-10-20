let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;
  mkSecretEnv = import ../../../../../lib/mkSecretEnv.nix;

  defaults = {
    name = "aiostreams";
    image = "ghcr.io/viren070/aiostreams:latest";
    ports = [ "3000:3000" ];
    openFirewall = true;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "media"
    "aiostreams"
  ];
  description = "AIOStreams Stremio addon aggregator (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      baseUrl = lib.mkOption {
        type = lib.types.str;
        description = "URL AIOStreams uses to build manifest URLs, e.g. `http://192.168.1.17:3000`.";
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/aiostreams";
        description = "Host directory for AIOStreams' SQLite database (mounted at `/app/data`).";
      };

      databaseUri = lib.mkOption {
        type = lib.types.str;
        default = "sqlite:///app/data/db.sqlite";
        description = "Database URI; the default SQLite file lives in `dataDir`.";
      };

      secretEnv = lib.mkOption {
        type = lib.types.str;
        default = "AIOSTREAMS_SECRET_KEY";
        description = "Environment name holding the 64-character hex `SECRET_KEY`.";
      };

      secretFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/secretspec/env";
        description = "Dotenv file the secret is read from.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      remap = mkSecretEnv {
        inherit lib pkgs;
        service = cfg.name;
        target = "/run/${cfg.name}.env";
        environmentFiles = [ cfg.secretFile ];
        mapping.SECRET_KEY = cfg.secretEnv;
        consumer = "docker-${cfg.name}.service";
      };
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg // {
          settings = cfg.settings // {
            inherit (cfg) baseUrl databaseUri;
            port = 3000;
          };
          volumes = [ "${cfg.dataDir}:/app/data" ] ++ cfg.volumes;
          environmentFiles = [ remap.environmentFile ];
        };
        inherit defaults;
      } args)

      {
        systemd.tmpfiles.rules = [
          "d '${cfg.dataDir}' 0755 root root -"
        ];
        systemd.services.${remap.unitName} = remap.unit;
      }
    ];
}
