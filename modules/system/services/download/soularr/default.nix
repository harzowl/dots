let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkSecretEnv = import ../../../../../lib/mkSecretEnv.nix;

  leaveDownloadsInPlacePatch = ./0002-leave-downloads-in-place.patch;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "soularr"
  ];
  description = "Soularr Lidarr/slskd bridge (native systemd service)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./package.nix { };
        description = "Pinned soularr package to run.";
      };

      patches.leave-downloads-in-place = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Apply the patch that reads `[Download Settings] stage_downloads`
          and leaves a completed album in its peer directory when the setting
          is false. Required when `stageDownloads` is false.
        '';
      };

      user = lib.mkOption {
        type = lib.types.str;
        description = ''
          Service user, as a name or a numeric UID. It must match the user the
          Lidarr and slskd containers run as, since soularr reads and, when
          staging, moves downloaded files in their shared directories.
        '';
      };

      group = lib.mkOption {
        type = lib.types.str;
        description = "Service group, as a name or a numeric GID.";
      };

      stateDir = lib.mkOption {
        type = lib.types.str;
        description = ''
          Durable state directory (`--var-dir`): the lock, the current search
          page, the failed-import denylist and, unless `logDir` is set, the log.
        '';
      };

      logDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Directory for soularr's rotating log. It becomes
          `[Logging] log_file = <logDir>/soularr.log` unless `settings` sets that
          key. Null keeps soularr's default (the log lives in `stateDir`).
        '';
      };

      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Seconds to wait after a run before starting the next one.";
      };

      lidarrUrl = lib.mkOption {
        type = lib.types.str;
        description = "Lidarr base URL reachable from this host.";
      };

      slskdUrl = lib.mkOption {
        type = lib.types.str;
        description = "slskd base URL reachable from this host.";
      };

      downloadDir = lib.mkOption {
        type = lib.types.str;
        description = ''
          Directory shared by slskd and Lidarr, as seen by this host. It becomes
          both `[Slskd] download_dir` and `[Lidarr] download_dir`; a host whose
          containers see different paths can override either key in `settings`.
        '';
      };

      stageDownloads = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Move each completed album into `downloadDir` for Lidarr to import.
          Disable it when another importer consumes the slskd tree: the album
          then stays below its peer directory instead of being flattened into
          the download root. Disabling it requires
          `patches.leave-downloads-in-place`.
        '';
      };

      secretEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "Lidarr.api_key" = "LIDARR_API_KEY";
          "Slskd.api_key" = "SLSKD_API_KEY";
        };
        description = ''
          Map a dotted INI path (`Section.key`) to a secret name read from
          `secretEnvSources`. The value is injected into the runtime INI and
          never enters the Nix store. A mapped path must not also appear in
          `settings`.
        '';
      };

      secretEnvSources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "/run/secretspec/env" ];
        description = "Dotenv files the secret values are read from, in order.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.attrsOf (
            lib.types.oneOf [
              lib.types.bool
              lib.types.int
              lib.types.float
              lib.types.str
              (lib.types.listOf (
                lib.types.oneOf [
                  lib.types.bool
                  lib.types.int
                  lib.types.float
                  lib.types.str
                ]
              ))
            ]
          )
        );
        default = { };
        example = {
          "Search Settings" = {
            search_source = "missing";
            number_of_albums_to_grab = 10;
            failed_import_denylist = true;
          };
          "Release Settings".accepted_formats = "CD,Digital Media,Vinyl";
        };
        description = ''
          The whole `config.ini`, as section -> key -> scalar. Values win over
          the typed conveniences (`lidarrUrl`, `slskdUrl`, `downloadDir`,
          `logDir`), so those are only defaults. Integers, floats and booleans
          are written by a runtime `configparser` renderer; lists are not
          accepted — an INI list is a comma-separated string.
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      envName = path: lib.toUpper (lib.replaceStrings [ "." " " "-" ] [ "_" "_" "_" ] path);

      typedSettings = {
        Lidarr = {
          host_url = cfg.lidarrUrl;
          download_dir = cfg.downloadDir;
        };
        Slskd = {
          host_url = cfg.slskdUrl;
          download_dir = cfg.downloadDir;
        };
        "Download Settings".stage_downloads = cfg.stageDownloads;
      }
      // lib.optionalAttrs (cfg.logDir != null) {
        Logging.log_file = "${cfg.logDir}/soularr.log";
      };

      package =
        if cfg.patches.leave-downloads-in-place then
          cfg.package.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ leaveDownloadsInPlacePatch ];
          })
        else
          cfg.package;

      settings = lib.recursiveUpdate typedSettings cfg.settings;
      settingsFile = pkgs.writeText "soularr-settings.json" (builtins.toJSON settings);

      envNames = map envName (lib.attrNames cfg.secretEnv);

      remap = mkSecretEnv {
        inherit lib pkgs;
        service = "soularr";
        target = "/run/soularr.env";
        environmentFiles = cfg.secretEnvSources;
        mapping = lib.mapAttrs' (path: secret: lib.nameValuePair (envName path) secret) cfg.secretEnv;
      };

      renderArgs = [
        "--settings"
        (toString settingsFile)
        "--output"
        "/run/soularr/config.ini"
      ]
      ++ map (path: "${path}=${envName path}") (lib.attrNames cfg.secretEnv);

      loop = pkgs.writeShellScript "soularr-loop" (builtins.readFile ./run-loop.sh);
      renderer = pkgs.writeText "soularr-render-config.py" (builtins.readFile ./render-config.py);
    in
    {
      assertions = [
        {
          assertion = lib.all (path: lib.hasAttr path cfg.secretEnv) [
            "Lidarr.api_key"
            "Slskd.api_key"
          ];
          message = "dots.system.services.download.soularr.secretEnv must map Lidarr.api_key and Slskd.api_key.";
        }
        {
          assertion = lib.all (path: !(lib.hasAttrByPath (lib.splitString "." path) settings)) (
            lib.attrNames cfg.secretEnv
          );
          message = "dots.system.services.download.soularr.secretEnv paths must not also be set in settings; secrets belong in the runtime INI only.";
        }
        {
          assertion = lib.length (lib.unique envNames) == lib.length envNames;
          message = "dots.system.services.download.soularr.secretEnv paths must map to distinct environment names.";
        }
        {
          assertion = cfg.stageDownloads || cfg.patches.leave-downloads-in-place;
          message = "dots.system.services.download.soularr.stageDownloads = false requires patches.leave-downloads-in-place = true.";
        }
      ];

      systemd = {
        services = {
          soularr = {
            description = "Soularr Lidarr/slskd bridge";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "${remap.unitName}.service"
            ];
            wants = [ "network-online.target" ];
            requires = [ "${remap.unitName}.service" ];
            path = [ pkgs.coreutils ];
            serviceConfig = {
              Type = "simple";
              User = cfg.user;
              Group = cfg.group;
              RuntimeDirectory = "soularr";
              RuntimeDirectoryMode = "0700";
              EnvironmentFile = [ remap.environmentFile ];
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectHome = true;
              ProtectSystem = "strict";
              ReadWritePaths = [
                cfg.downloadDir
                cfg.stateDir
              ]
              ++ lib.optional (cfg.logDir != null) cfg.logDir;
              ExecStartPre = lib.escapeShellArgs (
                [
                  "${pkgs.python3}/bin/python3"
                  (toString renderer)
                ]
                ++ renderArgs
              );
              ExecStart = lib.escapeShellArgs [
                (toString loop)
                (toString cfg.interval)
                "${package}/bin/soularr"
                "--config-dir"
                "/run/soularr"
                "--var-dir"
                cfg.stateDir
                "--no-lock-file"
              ];
              Restart = "on-failure";
              RestartSec = "30s";
            };
          };

          ${remap.unitName} = remap.unit;
        };

        tmpfiles.rules = [
          "d '${cfg.stateDir}' 0750 ${cfg.user} ${cfg.group} -"
        ]
        ++ lib.optional (cfg.logDir != null) "d '${cfg.logDir}' 0750 ${cfg.user} ${cfg.group} -";
      };
    };
}
