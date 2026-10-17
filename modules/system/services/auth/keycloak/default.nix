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
        inherit ((pkgs.formats.json { })) type;
        description = "Realm definition (roles + clients). `\${VAR}` placeholders are resolved from the environment.";
      };

      hostname = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public URL (no trailing slash). Defaults to `auth.<domain>`.";
      };

      hostnameAdmin = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Public URL the admin console is served on when it differs from
          `hostname` (`KC_HOSTNAME_ADMIN`). The host must reach Keycloak too.
        '';
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

      realmAdmins = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "me@example.com" ];
        description = "Usernames to grant the realm's `realm-admin` client role (full administration of this realm). Applied by the reconcile, so it is idempotent.";
      };

      extraVolumes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/nix/store/…-spi.jar:/opt/keycloak/providers/spi.jar:ro" ];
        description = ''
          Extra volume mounts for the Keycloak container, appended after the
          realm-import mount. Bind provider JARs here (at
          `/opt/keycloak/providers/<name>.jar`); because the container runs a
          non-optimized `start`, its implicit build picks them up on start, so
          no image bake is needed.
        '';
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "quay.io/keycloak/keycloak:latest";
        description = ''
          Keycloak container image. Pin a digest (`repo@sha256:…`) to keep an
          exact build — a newer `:latest` migrates the database schema on start
          and makes a rollback to a previous host impossible.
        '';
      };

      dbImage = lib.mkOption {
        type = lib.types.str;
        default = "postgres:17-alpine";
        description = ''
          PostgreSQL image for `keycloak-db`. Pin a digest (`repo@sha256:…`) to
          keep an exact build across hosts.
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
      domain = args.config.dots.system.core.domain;
      hostname = if cfg.hostname != null then cfg.hostname else "auth.${domain}";
      inherit (cfg) realm;

      # `userProfile`, `defaultRequiredActions` and `defaultRoles` are not fields
      # of Keycloak's realm representation (the live realm gets them from the
      # reconcile, below) — keep them out of the imported JSON so a fresh
      # `--import-realm` never sees an unknown field.
      realmJson = (pkgs.formats.json { }).generate "realm.json" (
        lib.removeAttrs realm [
          "userProfile"
          "defaultRequiredActions"
          "defaultRoles"
          "serviceAccountRoles"
        ]
      );

      # What `keycloak-reconcile` upserts into the existing realm.
      partialJson = (pkgs.formats.json { }).generate "realm-partial.json" {
        ifResourceExists = "OVERWRITE";
        roles = realm.roles or { };
        clients = realm.clients or [ ];
      };

      # Client roles to grant a service-account client's service account (e.g.
      # `realm-management:view-users` for a read-only directory reader). Not a
      # realm-representation field, and `partialImport` cannot carry it, so the
      # reconcile applies it: `[{ clientId; client; roles = [ … ]; }]`.
      serviceAccountRoles = realm.serviceAccountRoles or [ ];
      serviceAccountsJson =
        if serviceAccountRoles != [ ] then
          (pkgs.formats.json { }).generate "service-accounts.json" serviceAccountRoles
        else
          null;

      # The realm's declarative user profile (which fields users may self-edit in
      # the Account Console). `partialImport` does not carry it, so the reconcile
      # applies it separately with `kcadm update users/profile`. Only generated
      # when the consumer defines one, so we never wipe a profile with `{}`.
      userProfile = realm.userProfile or null;
      profileJson =
        if userProfile != null then
          (pkgs.formats.json { }).generate "user-profile.json" userProfile
        else
          null;

      smtp = realm.smtpServer or { };

      # The realm's display name, mail sender names, account theme and login
      # rule are realm fields, not part of the client/role partial import, so the
      # reconcile applies them with a plain `kcadm update realms/<realm>`.
      realmUpdate =
        let
          displayFlag = lib.optionalString (
            (realm.displayName or null) != null
          ) "-s 'displayName=${realm.displayName}' ";
          smtpFlags = lib.concatMapStrings (k: "-s 'smtpServer.${k}=${toString smtp.${k}}' ") (
            lib.attrNames smtp
          );
          # A realm field, so a `partialImport` never carries it and a Keycloak
          # restart does not re-import an existing realm: without this update the
          # account theme would only ever apply on the realm's first import.
          accountThemeFlag = lib.optionalString (
            (realm.accountTheme or null) != null
          ) "-s 'accountTheme=${realm.accountTheme}' ";
          # A realm field too: without this update an existing realm keeps
          # whatever it was first imported with, so a login could stay forced to
          # an email address after the declaration changes.
          emailAsUsernameFlag = lib.optionalString (
            (realm.registrationEmailAsUsername or null) != null
          ) "-s 'registrationEmailAsUsername=${lib.boolToString realm.registrationEmailAsUsername}' ";
        in
        lib.optionalString
          (displayFlag != "" || smtpFlags != "" || accountThemeFlag != "" || emailAsUsernameFlag != "")
          "kcadm update \"realms/\${REALM}\" ${displayFlag}${smtpFlags}${accountThemeFlag}${emailAsUsernameFlag}|| true";

      reconcile =
        lib.replaceStrings
          [
            "@PORT@"
            "@REALM@"
            "@ADMIN_USER@"
            "@PARTIAL_JSON@"
            "@PROFILE_JSON@"
            "@REALM_ADMINS@"
            "@DEFAULT_REQUIRED_ACTIONS@"
            "@DEFAULT_ROLES@"
            "@SERVICE_ACCOUNT_ROLES@"
            "@REALM_UPDATE@"
            "@ENV_FILE@"
            "@CONTAINER@"
          ]
          [
            (toString cfg.port)
            realm.realm
            cfg.adminUser
            (toString partialJson)
            (if profileJson != null then toString profileJson else "")
            (lib.concatStringsSep " " cfg.realmAdmins)
            (lib.concatStringsSep " " (realm.defaultRequiredActions or [ ]))
            (lib.concatStringsSep " " (realm.defaultRoles or [ ]))
            (if serviceAccountsJson != null then toString serviceAccountsJson else "")
            realmUpdate
            cfg.envFile
            "keycloak"
          ]
          (builtins.readFile ./reconcile.sh);

      db = {
        name = "keycloak-db";
        image = cfg.dbImage;
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
        inherit (cfg) image;
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
        ]
        ++ cfg.extraVolumes;
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
        }
        // lib.optionalAttrs (cfg.hostnameAdmin != null) {
          kcHostnameAdmin = "https://${cfg.hostnameAdmin}";
        };
      };
    in
    lib.mkMerge [
      (mkDockerService.config { spec = db; } args)
      (mkDockerService.config { spec = keycloak; } args)
      {
        networking.firewall.allowedTCPPorts = [ cfg.port ];

        systemd = {
          services.keycloak-reconcile = {
            description = "Reconcile the Keycloak realm";
            after = [ "docker-keycloak.service" ];
            path = [
              pkgs.curl
              pkgs.gettext
              pkgs.docker
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.jq
            ];
            serviceConfig.Type = "oneshot";
            script = reconcile;
          };

          # A deploy restarts Keycloak (its realm/config mounts change), and a
          # realm client isn't live until this reconcile runs — so retry often
          # (the script is cheap and exits immediately when Keycloak isn't up yet)
          # rather than letting a new client wait up to 15 minutes.
          timers.keycloak-reconcile = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "30s";
              OnUnitActiveSec = "1min";
            };
          };
        };
      }
    ];
}
