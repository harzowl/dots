# Navidrome — a music server / streamer, run from the `deluan/navidrome` image.
# It listens on :4533; the published host port is what the front proxy reaches.
#
# Configuration is passed as environment variables through `settings`, keyed by
# Navidrome's own setting names — each is mapped to `ND_<SETTING>` (uppercased,
# `.` -> `_`), so `musicFolder` -> `ND_MUSICFOLDER` and
# `"ExtAuth.TrustedSources"` -> `ND_EXTAUTH_TRUSTEDSOURCES`.
#
# Navidrome has NO native OIDC and no auth plugin hook, so logins are done by an
# authenticating proxy in front of it: set `"ExtAuth.TrustedSources"` to the
# proxy's network and it uses the `"ExtAuth.UserHeader"` (default `Remote-User`)
# to identify the user. Subsonic clients keep their own credentials via `/rest/*`
# (carve that path out of the proxy's authentication).
#
# The `plugins` option controls Navidrome's WASM plugin system (`.ndp` packages):
# `plugins.files` installs packages into the plugins folder declaratively, and
# `plugins.enable`/`autoReload`/`logLevel` map to the `Plugins.*` settings.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "navidrome";
    image = "deluan/navidrome:latest";
    # Loopback-only: the front proxy (host networking) reaches it on 127.0.0.1 and
    # `openFirewall = false` keeps it off the LAN and the mesh. External auth on
    # `/rest` trusts a source IP, so Navidrome must not be reachable directly.
    ports = [ "127.0.0.1:4533:4533" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "music"
    "navidrome"
  ];
  description = "Navidrome music server (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/navidrome/data";
        description = "Host directory for Navidrome's database and cache (mounted at `/data`).";
      };
      musicDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/navidrome/music";
        description = "Host directory holding the music library (mounted read-only at `/music`).";
      };
      dataOwner = lib.mkOption {
        type = lib.types.str;
        default = "1000:1000";
        description = ''
          Numeric `user:group` that owns the bind-mount directories. The image
          runs as UID/GID 1000, but docker creates a missing bind mount owned by
          root, which the container then cannot write.
        '';
      };
      plugins = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable Navidrome's (WASM) plugin system (`ND_PLUGINS_ENABLED`).";
        };
        autoReload = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Watch the plugins folder and reload on changes (`ND_PLUGINS_AUTORELOAD`).";
        };
        logLevel = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Plugin log level (`ND_PLUGINS_LOGLEVEL`); null inherits the global level.";
        };
        files = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [ ];
          description = ''
            `.ndp` plugin packages to install into the plugins folder. They land
            in `<dataDir>/plugins` and are picked up on start (or on rescan).
          '';
        };
      };
      admin = {
        username = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Ensure a Navidrome admin account with this username exists. Navidrome
            has no OIDC, so this seeds the local admin; logins still go through
            the gate. Requires `passwordFile`.
          '';
        };
        passwordFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File holding the admin account's password (e.g. the secretspec env path).";
        };
        passwordKey = lib.mkOption {
          type = lib.types.str;
          default = "NAVIDROME_ADMIN_PASSWORD";
          description = ''
            When `passwordFile` is a dotenv (like `/run/secretspec/env`), the key
            whose value is the admin password. Ignored if the file holds the bare
            password.
          '';
        };
        ensureAdmins = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Navidrome usernames to keep marked as admins (e.g. the Keycloak
            admins). They must already exist in Navidrome.
          '';
        };
        ensureUsers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Navidrome usernames to CREATE if missing (non-admin). External
            (ExtAuth) authentication on `/rest` does not auto-provision — only a
            web-index load does — so accounts must exist before a client can
            authenticate via the proxy header. A random local password is set;
            logins go through the gate.
          '';
        };
        sync = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                url = lib.mkOption {
                  type = lib.types.str;
                  description = "Keycloak base URL (reachable from this host).";
                };
                realm = lib.mkOption {
                  type = lib.types.str;
                  description = "Realm whose users are mirrored into Navidrome accounts.";
                };
                clientId = lib.mkOption {
                  type = lib.types.str;
                  description = "Service-account client id (confidential, with `realm-management:view-users`).";
                };
                clientSecretFile = lib.mkOption {
                  type = lib.types.path;
                  description = "File holding the client secret.";
                };
                clientSecretKey = lib.mkOption {
                  type = lib.types.str;
                  description = "Key in `clientSecretFile` holding the secret.";
                };
              };
            }
          );
          default = null;
          description = ''
            Mirror the realm's users into local Navidrome accounts, creating any
            that are missing. Needed because ExtAuth does not auto-provision on
            `/rest`, so every user who connects with a native client must have an
            account. Re-run periodically so new users appear without a deploy.
          '';
        };
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib;
      pluginsDir = "${cfg.dataDir}/plugins";

      envValue =
        v:
        if lib.isBool v then
          (if v then "true" else "false")
        else if lib.isList v then
          lib.concatStringsSep "," (map toString v)
        else
          toString v;

      # `musicFolder` -> `ND_MUSICFOLDER`, `ExtAuth.TrustedSources` ->
      # `ND_EXTAUTH_TRUSTEDSOURCES`.
      ndEnvironment = lib.mapAttrs' (
        k: v: lib.nameValuePair ("ND_" + lib.toUpper (lib.replaceStrings [ "." ] [ "_" ] k)) (envValue v)
      ) cfg.settings;

      pluginEnvironment = {
        ND_PLUGINS_ENABLED = envValue cfg.plugins.enable;
        ND_PLUGINS_FOLDER = "/data/plugins";
        ND_PLUGINS_AUTORELOAD = envValue cfg.plugins.autoReload;
      }
      // lib.optionalAttrs (cfg.plugins.logLevel != null) {
        ND_PLUGINS_LOGLEVEL = cfg.plugins.logLevel;
      };
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg // {
          settings = { };
          volumes = [
            "${cfg.dataDir}:/data"
            "${cfg.musicDir}:/music:ro"
          ];
        };
        inherit defaults;
      } args)
      {
        systemd = {
          tmpfiles.rules = [
            "d '${cfg.dataDir}' 0755 ${cfg.dataOwner} - -"
            "d '${cfg.musicDir}' 0755 ${cfg.dataOwner} - -"
            "d '${pluginsDir}' 0700 ${cfg.dataOwner} - -"
          ]
          ++ map (f: "C '${pluginsDir}/${baseNameOf f}' 0600 ${cfg.dataOwner} - - ${f}") cfg.plugins.files;

          # Navidrome has no OIDC, so seed its admin account and keep the listed
          # admins marked admin. Idempotent, and re-checked when the container
          # (re)starts. The password comes from a file (e.g. a secretspec path).
          services."${cfg.name}-admin" = lib.mkIf (cfg.admin.username != null) {
            description = "Ensure the Navidrome admin account";
            after = [ "docker-${cfg.name}.service" ];
            requires = [ "docker-${cfg.name}.service" ];
            partOf = [ "docker-${cfg.name}.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            path =
              with args.pkgs;
              [
                docker
                util-linux
                coreutils
                gnugrep
              ]
              ++ lib.optionals (cfg.admin.sync != null) [
                curl
                jq
              ];
            script = ''
              set -u
              # A deploy restarts the container; wait for it before touching it.
              for _ in $(seq 1 60); do
                docker exec ${cfg.name} /app/navidrome user list -n >/dev/null 2>&1 && break
                sleep 2
              done

              if docker exec ${cfg.name} /app/navidrome user list -n 2>/dev/null | cut -d, -f2 | grep -qx '${cfg.admin.username}'; then
                echo "Navidrome admin '${cfg.admin.username}' already exists"
              else
                pw="$(sed -n 's/^${cfg.admin.passwordKey}=//p' ${toString cfg.admin.passwordFile})"
                # The CLI prompts on a TTY; feed it via a PTY. The PTY echoes the
                # input, so keep its output off the journal.
                printf '%s\n%s\n' "$pw" "$pw" | script -qec \
                  "docker exec -it ${cfg.name} /app/navidrome user create --username '${cfg.admin.username}' --admin -n" /dev/null >/dev/null 2>&1 \
                  || echo "warning: could not create the Navidrome admin"
              fi
              ${lib.concatMapStrings (u: ''
                if docker exec ${cfg.name} /app/navidrome user list -n 2>/dev/null | cut -d, -f2 | grep -qx ${lib.escapeShellArg u}; then
                  :
                else
                  # ExtAuth on /rest does not auto-provision; seed the account with
                  # a random local password (logins go through the gate).
                  pw="$(head -c 24 /dev/urandom | base64)"
                  printf '%s\n%s\n' "$pw" "$pw" | script -qec \
                    "docker exec -it ${cfg.name} /app/navidrome user create --username ${lib.escapeShellArg u} -n" /dev/null >/dev/null 2>&1 \
                    && echo "created Navidrome user '${u}'" \
                    || echo "warning: could not create Navidrome user '${u}'"
                fi
              '') cfg.admin.ensureUsers}
              ${lib.optionalString (cfg.admin.sync != null) ''
                # Mirror the realm's users through a read-only service account:
                # ExtAuth on /rest does not auto-provision, so create what is missing.
                synccfg="$(mktemp)"
                chmod 600 "$synccfg"
                sed -n 's/^${cfg.admin.sync.clientSecretKey}=//p' ${toString cfg.admin.sync.clientSecretFile} | tr -d '\n' > "$synccfg"
                token="$(curl -fsS -X POST "${cfg.admin.sync.url}/realms/${cfg.admin.sync.realm}/protocol/openid-connect/token" \
                  -d grant_type=client_credentials -d client_id=${cfg.admin.sync.clientId} \
                  --data-urlencode "client_secret@$synccfg" 2>/dev/null | jq -r '.access_token // empty')"
                rm -f "$synccfg"
                if [ -n "$token" ]; then
                  existing="$(docker exec ${cfg.name} /app/navidrome user list -n 2>/dev/null | cut -d, -f2)"
                  for u in $(curl -fsS -H "Authorization: Bearer $token" \
                    "${cfg.admin.sync.url}/admin/realms/${cfg.admin.sync.realm}/users?max=5000&briefRepresentation=true" 2>/dev/null \
                    | jq -r '.[].username'); do
                    printf '%s\n' "$existing" | grep -qx "$u" && continue
                    pw="$(head -c 24 /dev/urandom | base64)"
                    printf '%s\n%s\n' "$pw" "$pw" | script -qec \
                      "docker exec -it ${cfg.name} /app/navidrome user create --username '$u' -n" /dev/null >/dev/null 2>&1 \
                      && echo "created Navidrome user '$u' (from Keycloak)" \
                      || echo "warning: could not create Navidrome user '$u'"
                  done
                else
                  echo "warning: could not read the realm user list"
                fi
              ''}
              ${lib.concatMapStrings (u: ''
                docker exec ${cfg.name} /app/navidrome user edit --user '${u}' --set-admin -n >/dev/null 2>&1 || true
              '') cfg.admin.ensureAdmins}
            '';
          };
          timers."${cfg.name}-admin" = lib.mkIf (cfg.admin.username != null && cfg.admin.sync != null) {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "2min";
              OnUnitActiveSec = "5min";
            };
          };
        };
        virtualisation.oci-containers.containers.${cfg.name}.environment =
          ndEnvironment // pluginEnvironment;
      }
    ];
}
