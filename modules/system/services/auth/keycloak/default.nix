# Keycloak — the single sign-on provider for the services that need accounts.
#
# Runs two OCI containers on one host:
#
#   * `keycloak-db` — PostgreSQL, published on loopback only. It uses `trust`
#     auth (the only reachable peer is the Keycloak container on the same host),
#     so no database password is stored anywhere.
#   * `keycloak`   — Keycloak itself, on the host network so it can reach that
#     loopback database and bind the public port the front proxy targets.
#
# The realm is seeded from `realmFile` on first boot (`--import-realm`); Keycloak
# substitutes `${VAR}` placeholders in that file from the process environment, so
# client secrets are passed via `environmentFiles` (e.g. the secretspec env file)
# and never enter the Nix store. `--optimized` is deliberately NOT used — the
# stock image is not built for our build-time options (KC_DB, KC_HEALTH_ENABLED),
# so `start` must run its implicit build.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "auth"
    "keycloak"
  ];
  description = "Keycloak single sign-on (OCI containers)";

  options =
    { lib, ... }:
    {
      realmFile = lib.mkOption {
        type = lib.types.path;
        description = "Realm-import JSON (seeds the realm on first boot; `\${VAR}` placeholders are resolved from the environment).";
      };

      hostname = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public URL (no trailing slash). Defaults to `auth.<domain>`.";
      };

      adminUser = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "Bootstrap admin username (`KC_BOOTSTRAP_ADMIN_USERNAME`).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Host port Keycloak binds (the front proxy targets it).";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Dotenv files (e.g. the secretspec env file) providing `KC_BOOTSTRAP_ADMIN_PASSWORD` and the client secrets referenced by the realm.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
      domain = args.config.dots.system.core.domain;
      hostname = if cfg.hostname != null then cfg.hostname else "auth.${domain}";
      realm = builtins.fromJSON (builtins.readFile cfg.realmFile);
      realmJson = (pkgs.formats.json { }).generate "realm.json" realm;

      db = {
        name = "keycloak-db";
        image = "postgres:17-alpine";
        backend = "docker";
        openFirewall = false;
        ports = [ "127.0.0.1:5432:5432" ];
        volumes = [ "/var/lib/keycloak-db:/var/lib/postgresql/data" ];
        cmd = [ ];
        extraOptions = [ ];
        environmentFiles = [ ];
        settings = {
          postgresDb = "keycloak";
          postgresUser = "keycloak";
          postgresHostAuthMethod = "trust";
        };
      };

      keycloak = {
        name = "keycloak";
        image = "quay.io/keycloak/keycloak:latest";
        backend = "docker";
        openFirewall = true;
        ports = [ ];
        cmd = [
          "start"
          "--import-realm"
        ];
        # Host networking: reach the loopback Postgres and bind `cfg.port`.
        extraOptions = [ "--network=host" ];
        inherit (cfg) environmentFiles;
        volumes = [
          "${realmJson}:/opt/keycloak/data/import/${realm.realm}-realm.json:ro"
        ];
        settings = {
          kcDb = "postgres";
          kcDbUrl = "jdbc:postgresql://127.0.0.1:5432/keycloak";
          kcDbUsername = "keycloak";
          # Ignored (loopback Postgres trusts); required to be non-empty.
          kcDbPassword = "keycloak";
          kcHostname = "https://${hostname}";
          kcProxyHeaders = "xforwarded";
          kcHttpEnabled = true;
          kcHttpPort = cfg.port;
          kcHealthEnabled = true;
          kcBootstrapAdminUsername = cfg.adminUser;
        };
      };
    in
    lib.mkMerge [
      (mkDockerService.config { spec = db; } args)
      (mkDockerService.config { spec = keycloak; } args)
      {
        networking.firewall.allowedTCPPorts = [ cfg.port ];
      }
    ];
}
