# Keycloak — single sign-on for the services that need accounts.
#
# Runs two OCI containers:
#
#   * `keycloak-db` — PostgreSQL, loopback only, `trust` auth (its only peer is
#     the Keycloak container on the same host), so no DB password is stored.
#   * `keycloak`   — Keycloak on the host network, so it reaches that loopback
#     database and binds the public port the front proxy targets.
#
# The realm is *generated* by the consumer from the services that declare an
# `sso` block and passed as `realm` here. It is seeded with `--import-realm` on
# first boot, and reconciled on every activation by `keycloak-reconcile` (Admin
# API), so later edits to that realm take effect without recreating it.
# `${VAR}` placeholders in the realm are resolved from the environment (the
# secretspec env file), keeping client secrets out of the store. `--optimized`
# is not used: the stock image is not built for our build-time options, so
# `start` runs its implicit build.
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
    { lib, pkgs, ... }:
    {
      realm = lib.mkOption {
        type = (pkgs.formats.json { }).type;
        description = "Realm definition (roles + clients). `\${VAR}` placeholders are resolved from the environment.";
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
        description = "Dotenv files (e.g. the secretspec env file) providing `KC_BOOTSTRAP_ADMIN_PASSWORD` and the client secrets.";
      };

      envFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/secretspec/env";
        description = "The env file the reconcile unit sources for the admin password and client secrets.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
      domain = args.config.dots.system.core.domain;
      hostname = if cfg.hostname != null then cfg.hostname else "auth.${domain}";
      realm = cfg.realm;

      realmJson = (pkgs.formats.json { }).generate "realm.json" realm;

      # What `keycloak-reconcile` upserts into the existing realm.
      partialJson = (pkgs.formats.json { }).generate "realm-partial.json" {
        ifResourceExists = "OVERWRITE";
        roles = realm.roles or { };
        clients = realm.clients or [ ];
      };

      reconcile =
        lib.replaceStrings
          [ "@PORT@" "@REALM@" "@ADMIN_USER@" "@PARTIAL_JSON@" "@ENV_FILE@" "@CONTAINER@" ]
          [ (toString cfg.port) realm.realm cfg.adminUser (toString partialJson) cfg.envFile "keycloak" ]
          (builtins.readFile ./reconcile.sh);

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

        systemd.services.keycloak-reconcile = {
          description = "Reconcile the Keycloak realm";
          after = [ "docker-keycloak.service" ];
          path = [
            pkgs.curl
            pkgs.gettext
            pkgs.docker
          ];
          serviceConfig.Type = "oneshot";
          script = reconcile;
        };

        # A deploy restarts Keycloak (its realm/config mounts change), and a
        # realm client isn't live until this reconcile runs — so retry often
        # (the script is cheap and exits immediately when Keycloak isn't up yet)
        # rather than letting a new client wait up to 15 minutes.
        systemd.timers.keycloak-reconcile = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "1min";
          };
        };
      }
    ];
}
