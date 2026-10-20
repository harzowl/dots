let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "jellyfin";
    image = "jellyfin/jellyfin:12.2";
    ports = [ "8096:8096" ];
    openFirewall = true;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "media"
    "jellyfin"
  ];
  description = "Jellyfin media server (OCI container) with optional Keycloak OIDC";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      configDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/jellyfin/config";
        description = "Host directory for Jellyfin's configuration (mounted at `/config`).";
      };

      cacheDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/jellyfin/cache";
        description = "Host directory for Jellyfin's cache (mounted at `/cache`).";
      };

      mediaDir = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/media";
        description = "Host directory holding the media library (mounted read-only at `/media`).";
      };

      dataOwner = lib.mkOption {
        type = lib.types.str;
        default = "1000:1000";
        description = ''
          Numeric `user:group` that owns the config and cache directories. The
          image runs as UID/GID 1000, but docker creates a missing bind mount
          owned by root, which the container then cannot write.
        '';
      };

      sso = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "Keycloak OIDC through the SSO-Auth plugin";

            provider = lib.mkOption {
              type = lib.types.str;
              default = "keycloak";
              description = "Provider name used in the plugin's redirect path.";
            };

            endpoint = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "OIDC issuer URL, e.g. `https://auth.example/realms/realm`.";
            };

            clientId = lib.mkOption {
              type = lib.types.str;
              default = "jellyfin";
              description = "OIDC client ID.";
            };

            clientSecretEnv = lib.mkOption {
              type = lib.types.str;
              default = "JELLYFIN_OIDC_CLIENT_SECRET";
              description = "Environment name holding the OIDC client secret.";
            };

            secretFile = lib.mkOption {
              type = lib.types.str;
              default = "/run/secretspec/env";
              description = "Dotenv file the client secret is read from.";
            };

            scopes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "email" ];
              description = "Additional OIDC scopes.";
            };

            schemeOverride = lib.mkOption {
              type = lib.types.str;
              default = "https";
              description = "Scheme used in the redirect URI.";
            };

            portOverride = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              description = "Port used in the redirect URI; null uses the request's Host header.";
            };

            newPath = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Use the descriptive `/sso/OID/redirect/<provider>` callback path.";
            };

            enableAuthorization = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Require provider roles before allowing a Jellyfin login.";
            };

            enableAllFolders = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Grant new SSO users access to every library.";
            };

            adminRoles = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Provider roles that make a user a Jellyfin administrator.";
            };

            roles = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Provider roles allowed to log in.";
            };

            roleClaim = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Claim path holding the provider roles, e.g. `realm_access.roles`.";
            };

            disablePushedAuthorization = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Disable PAR in the SSO plugin. Keycloak rejects the plugin's PAR request; PKCE remains enabled.";
            };

            pluginVersion = lib.mkOption {
              type = lib.types.str;
              default = "5.1.1";
              description = "SSO-Auth plugin version to install.";
            };

            pluginHash = lib.mkOption {
              type = lib.types.str;
              default = "sha256-2xJrR2O9o6N1T6IQMjL8A+8b+SnP7aNfLprznIdSM7E=";
              description = "Hash of the SSO-Auth plugin ZIP for `pluginVersion`.";
            };
          };
        };
        default = { };
        description = "Optional Keycloak OIDC login through the SSO-Auth plugin.";
      };

      patches = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Patch files applied to the bundled Jellyfin web UI index.html when SSO is enabled.";
      };

      pluginRepositories = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption { type = lib.types.str; };
              url = lib.mkOption { type = lib.types.str; };
            };
          }
        );
        default = [ ];
        description = "Jellyfin plugin repositories written to `system.xml` before the container starts.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      ssoPlugin =
        if cfg.sso.enable then
          pkgs.stdenvNoCC.mkDerivation {
            pname = "jellyfin-plugin-sso";
            version = cfg.sso.pluginVersion;
            src = pkgs.fetchurl {
              url = "https://github.com/K0lin/jellyfin-plugin-sso/releases/download/v${cfg.sso.pluginVersion}/sso-authentication_${cfg.sso.pluginVersion}.zip";
              hash = cfg.sso.pluginHash;
            };
            nativeBuildInputs = [ pkgs.unzip ];
            unpackPhase = "unzip $src";
            installPhase = "mkdir -p $out; cp -r . $out/";
          }
        else
          null;

      pluginDir = "SSO-Auth_${cfg.sso.pluginVersion}";
      renderer = pkgs.writeText "jellyfin-render-sso.py" (builtins.readFile ./render-sso.py);
      repositoriesRenderer = pkgs.writeText "jellyfin-render-repositories.py" (
        builtins.readFile ./render-repositories.py
      );
      repositoriesJson = pkgs.writeText "jellyfin-repositories.json" (
        builtins.toJSON cfg.pluginRepositories
      );
      ssoConfigService = "${cfg.name}-sso-config";
      repositoriesService = "${cfg.name}-repositories";

      patchedIndex =
        if cfg.sso.enable && cfg.patches != [ ] then
          pkgs.runCommand "jellyfin-web-index" { nativeBuildInputs = [ pkgs.patch ]; } ''
            cp ${./web/index.html} index.html
            ${lib.concatMapStrings (p: "patch -p1 < ${p}\n") cfg.patches}
            mkdir -p $out
            cp index.html $out/index.html
          ''
        else
          null;

      volumes = [
        "${cfg.configDir}:/config"
        "${cfg.cacheDir}:/cache"
        "${cfg.mediaDir}:/media:ro"
      ]
      ++ lib.optional cfg.sso.enable "${ssoPlugin}:/config/plugins/${pluginDir}:ro"
      ++ lib.optional (
        patchedIndex != null
      ) "${patchedIndex}/index.html:/jellyfin/jellyfin-web/index.html:ro"
      ++ cfg.volumes;
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg // {
          inherit volumes;
        };
        inherit defaults;
      } args)

      {
        assertions = [
          {
            assertion = !cfg.sso.enable || cfg.sso.endpoint != "";
            message = "dots.system.services.media.jellyfin.sso.endpoint must be set when SSO is enabled.";
          }
          {
            assertion = !cfg.sso.enable || cfg.sso.clientSecretEnv != "";
            message = "dots.system.services.media.jellyfin.sso.clientSecretEnv must not be empty.";
          }
        ];

        systemd.tmpfiles.rules = [
          "d '${cfg.configDir}' 0755 ${cfg.dataOwner} - -"
          "d '${cfg.cacheDir}' 0755 ${cfg.dataOwner} - -"
          "d '${cfg.configDir}/plugins/configurations' 0755 ${cfg.dataOwner} - -"
        ];
      }

      (lib.mkIf cfg.sso.enable {
        systemd.services.${ssoConfigService} = {
          description = "Render Jellyfin SSO-Auth configuration";
          after = [ "secretspec.service" ];
          wants = [ "secretspec.service" ];
          before = [ "docker-${cfg.name}.service" ];
          requiredBy = [ "docker-${cfg.name}.service" ];
          environment = {
            JELLYFIN_SSO_PROVIDER = cfg.sso.provider;
            JELLYFIN_SSO_ENDPOINT = cfg.sso.endpoint;
            JELLYFIN_SSO_CLIENT_ID = cfg.sso.clientId;
            JELLYFIN_SSO_SECRET_ENV = cfg.sso.clientSecretEnv;
            JELLYFIN_SSO_CONFIG_DIR = cfg.configDir;
            JELLYFIN_SSO_OWNER = cfg.dataOwner;
            JELLYFIN_SSO_SCHEME = cfg.sso.schemeOverride;
            JELLYFIN_SSO_PORT = if cfg.sso.portOverride != null then toString cfg.sso.portOverride else "";
            JELLYFIN_SSO_NEW_PATH = lib.boolToString cfg.sso.newPath;
            JELLYFIN_SSO_DISABLE_PUSHED_AUTHORIZATION = lib.boolToString cfg.sso.disablePushedAuthorization;
            JELLYFIN_SSO_ENABLE_AUTHORIZATION = lib.boolToString cfg.sso.enableAuthorization;
            JELLYFIN_SSO_ENABLE_ALL_FOLDERS = lib.boolToString cfg.sso.enableAllFolders;
            JELLYFIN_SSO_ADMIN_ROLES = lib.concatStringsSep "," cfg.sso.adminRoles;
            JELLYFIN_SSO_ROLES = lib.concatStringsSep "," cfg.sso.roles;
            JELLYFIN_SSO_ROLE_CLAIM = cfg.sso.roleClaim;
            JELLYFIN_SSO_SCOPES = lib.concatStringsSep "," cfg.sso.scopes;
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            EnvironmentFile = [ cfg.sso.secretFile ];
            ExecStart = "${pkgs.python3}/bin/python3 ${renderer}";
          };
        };

        systemd.services."docker-${cfg.name}" = {
          after = [ "${ssoConfigService}.service" ];
          requires = [ "${ssoConfigService}.service" ];
        };
      })

      (lib.mkIf (cfg.pluginRepositories != [ ]) {
        systemd.services.${repositoriesService} = {
          description = "Write Jellyfin plugin repositories";
          after = [ "systemd-tmpfiles-setup.service" ];
          before = [ "docker-${cfg.name}.service" ];
          requiredBy = [ "docker-${cfg.name}.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.python3}/bin/python3 ${repositoriesRenderer} --config ${cfg.configDir}/config/system.xml --repositories ${repositoriesJson} --owner ${cfg.dataOwner}";
          };
        };

        systemd.services."docker-${cfg.name}" = {
          after = [ "${repositoriesService}.service" ];
          requires = [ "${repositoriesService}.service" ];
        };
      })
    ];
}
