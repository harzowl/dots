# Secrets never enter the Nix store. `secretEnv` maps a `NAVISCOUT_*` name to a
# neutral key found in `environmentFiles`, and a oneshot unit writes the
# prefixed dotenv systemd reads. The source files stay the consumer's.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;

  serviceName = "naviscout";
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "music"
    "naviscout"
  ];
  description = "naviscout catalogue discovery proxy in front of Navidrome";

  imports =
    args:
    args.lib.optional (args ? naviscout && args.naviscout != null) args.naviscout.nixosModules.default;

  options =
    { lib, ... }:
    let
      inherited =
        type: description:
        lib.mkOption {
          inherit type description;
          default = null;
        };
    in
    {
      upstreamUrl = lib.mkOption {
        type = lib.types.str;
        description = "Base URL of the Subsonic/OpenSubsonic server naviscout augments.";
      };

      listen = inherited (lib.types.nullOr lib.types.str) ''
        Address the server listens on (`host:port`). Null keeps naviscout's
        default.
      '';

      dataDir = inherited (lib.types.nullOr lib.types.str) ''
        Durable state directory (catalogue database and related stores). Null
        keeps naviscout's default.
      '';

      cacheDir = inherited (lib.types.nullOr lib.types.str) ''
        Regenerable state directory (cover and playback caches). Null keeps
        naviscout's default.
      '';

      user = inherited (lib.types.nullOr lib.types.str) ''
        Service user. Null keeps naviscout's default.
      '';

      group = inherited (lib.types.nullOr lib.types.str) ''
        Service group. Null keeps naviscout's default.
      '';

      uid = inherited (lib.types.nullOr lib.types.int) ''
        Fixed numeric UID for the static service user; null lets NixOS pick
        one. Set this to keep a store migrated from an existing deployment
        owned by its former uid.
      '';

      gid = inherited (lib.types.nullOr lib.types.int) ''
        Fixed numeric GID for the static service group; null lets NixOS pick
        one.
      '';

      dynamicUser = inherited (lib.types.nullOr lib.types.bool) ''
        Run under a systemd DynamicUser. Null keeps naviscout's default.
      '';

      restart = inherited (lib.types.nullOr lib.types.str) ''
        systemd `Restart=` policy. Null keeps naviscout's default.
      '';

      restartSec = inherited (lib.types.nullOr lib.types.str) ''
        Delay between restarts. Null keeps naviscout's default.
      '';

      openFirewall = inherited (lib.types.nullOr lib.types.bool) ''
        Open the listening port in the host firewall. Null keeps naviscout's
        default.
      '';

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Dotenv files read by systemd before it drops privileges. This is the
          home for credentials; they never enter the Nix store.
        '';
      };

      credentials = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Files loaded with `LoadCredential=NAME:SOURCE`, for a consumer that
          prefers systemd credentials over an environment file.
        '';
      };

      secretEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          NAVISCOUT_LIDARR_API_KEY = "LIDARR_API_KEY";
        };
        description = ''
          Map a `NAVISCOUT_*` env name to a neutral secret name looked up in
          `environmentFiles`. The values are re-emitted into a runtime dotenv,
          so a secret never enters `extraEnv` (the Nix store).
        '';
      };

      extraEnv = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.bool
            lib.types.int
            lib.types.float
            lib.types.str
            (lib.types.listOf (
              lib.types.oneOf [
                lib.types.int
                lib.types.str
              ]
            ))
          ]
        );
        default = { };
        example = {
          NAVISCOUT_NATIVE_ENABLED = true;
          NAVISCOUT_YTDLP_SOURCE_ORDER = [
            "soundcloud"
            "bandcamp"
          ];
        };
        description = ''
          Generic `NAVISCOUT_*` settings, passed through as the service's
          environment. Bools render as `true`/`false` and lists are
          comma-joined. **Never put a secret here**: the Nix store is
          world-readable; use `secretEnv` or `environmentFiles`.
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      secretEnvFile = "/run/${serviceName}.env";
      remapEnabled = cfg.secretEnv != { };

      envValue =
        value:
        if lib.isBool value then
          lib.boolToString value
        else if lib.isList value then
          lib.concatStringsSep "," (map toString value)
        else
          toString value;

      whenSet =
        name: value:
        lib.optionalAttrs (value != null) {
          ${name} = value;
        };

      remapScript = pkgs.writeShellScript "naviscout-secrets-env" (builtins.readFile ./secrets-env.sh);
      remapArgs = lib.concatMapStringsSep " " lib.escapeShellArg (
        [ secretEnvFile ]
        ++ cfg.environmentFiles
        ++ [ "--" ]
        ++ lib.mapAttrsToList (env: secret: "${env}=${secret}") cfg.secretEnv
      );
    in
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = args ? naviscout;
            message = "dots.system.services.music.naviscout needs the naviscout flake as a special argument.";
          }
          {
            assertion = !remapEnabled || cfg.environmentFiles != [ ];
            message = "dots.system.services.music.naviscout.secretEnv needs environmentFiles to read the secrets from.";
          }
          {
            assertion = (cfg.uid == null && cfg.gid == null) || cfg.dynamicUser == false;
            message = "dots.system.services.music.naviscout.uid/gid need dynamicUser = false.";
          }
        ];

        services.naviscout = {
          enable = true;
          inherit (cfg) upstreamUrl credentials;
          environmentFiles = cfg.environmentFiles ++ lib.optional remapEnabled secretEnvFile;
          settings = lib.mapAttrs (_: envValue) cfg.extraEnv;
        }
        // whenSet "listen" cfg.listen
        // whenSet "dataDir" cfg.dataDir
        // whenSet "cacheDir" cfg.cacheDir
        // whenSet "user" cfg.user
        // whenSet "group" cfg.group
        // whenSet "dynamicUser" cfg.dynamicUser
        // whenSet "restart" cfg.restart
        // whenSet "restartSec" cfg.restartSec
        // whenSet "openFirewall" cfg.openFirewall;

        users = {
          users = lib.mkIf (cfg.user != null && cfg.uid != null) {
            ${cfg.user}.uid = cfg.uid;
          };
          groups = lib.mkIf (cfg.group != null && cfg.gid != null) {
            ${cfg.group}.gid = cfg.gid;
          };
        };

        systemd.services.${serviceName} = lib.mkIf remapEnabled {
          after = [ "${serviceName}-env.service" ];
          wants = [ "${serviceName}-env.service" ];
        };
      }

      (lib.mkIf remapEnabled {
        systemd.services."${serviceName}-env" = {
          description = "Map the naviscout secrets into their NAVISCOUT_ env names";
          after = [ "secretspec.service" ];
          wants = [ "secretspec.service" ];
          before = [ "${serviceName}.service" ];
          partOf = [ "secretspec.service" ];
          wantedBy = [ "multi-user.target" ];
          path = [
            pkgs.coreutils
            pkgs.gnused
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${remapScript} ${remapArgs}";
          };
        };
      })
    ];
}
