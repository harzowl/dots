let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "slskd-import"
  ];
  description = "Import completed downloads into beets";

  options =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      sources = lib.mkOption {
        type = lib.types.nonEmptyListOf (
          lib.types.submodule {
            options = {
              completeDir = lib.mkOption {
                type = lib.types.str;
                description = "Completed-download root for this source.";
              };

              incompleteDir = lib.mkOption {
                type = lib.types.str;
                description = "Incomplete-download root for this source, used to skip albums still in progress.";
              };
            };
          }
        );
        description = "One complete/incomplete directory pair per download source.";
      };

      topLevelAlbums = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Treat a top-level directory without a `directories` subdirectory as an
          album root, so an album staged in the download root (or a legacy flat
          download) is imported and pruned rather than skipped. Off by default:
          a top-level directory is normally a Soulseek user.
        '';
      };

      staleAfter = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3600;
        description = ''
          Remove a directory whose newest file is older than this many seconds.
          Incomplete trees are always eligible. In a complete tree only albums
          already marked duplicate or error are removed, plus empty directories,
          so an album waiting to be imported is never removed. Set to 0 to
          disable.
        '';
      };

      user = lib.mkOption {
        type = lib.types.str;
        description = "User the importer and `beet` run as; it must own or share the beets library and media trees.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "users";
        description = "Group the importer runs as and the group made writable on the download roots.";
      };

      settleSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 120;
        description = "Minimum age of the newest file in an album before it is imported.";
      };

      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Seconds to wait after a run finishes before starting the next one.";
      };

      beetsPackage = lib.mkOption {
        type = lib.types.package;
        default = config.dots.programs.music.beets.wrapper or pkgs.beets;
        description = "Package whose `bin/beet` performs the import; the default is the configured beets wrapper.";
      };

      qbittorrent = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              url = lib.mkOption {
                type = lib.types.str;
                description = "qBittorrent WebUI base URL.";
              };

              username = lib.mkOption {
                type = lib.types.str;
                default = "admin";
                description = "qBittorrent WebUI username.";
              };

              passwordFile = lib.mkOption {
                type = lib.types.str;
                description = "File holding the WebUI password; loaded as the `qbittorrent-password` systemd credential.";
              };

              pathMappings = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      remote = lib.mkOption {
                        type = lib.types.str;
                        description = "Path as seen by qBittorrent.";
                      };

                      local = lib.mkOption {
                        type = lib.types.str;
                        description = "The same path as seen by the importer.";
                      };
                    };
                  }
                );
                default = [ ];
                description = "Map qBittorrent content paths to the importer's filesystem. Only albums below a `local` root are considered for removal.";
              };
            };
          }
        );
        default = null;
        description = "Remove a completed torrent from qBittorrent once its album is imported.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      script = pkgs.writeText "slskd-import.py" (builtins.readFile ./slskd-import.py);

      sourceArgs = lib.concatMap (source: [
        "--complete"
        source.completeDir
        "--incomplete"
        source.incompleteDir
      ]) cfg.sources;

      tmpfilesRules = lib.concatMap (source: [
        "d '${source.completeDir}' 2775 ${cfg.user} ${cfg.group} -"
        "d '${source.incompleteDir}' 2775 ${cfg.user} ${cfg.group} -"
      ]) cfg.sources;

      qbtArgs = lib.optionals (cfg.qbittorrent != null) (
        [
          "--qbt-url"
          cfg.qbittorrent.url
          "--qbt-username"
          cfg.qbittorrent.username
          "--qbt-password-file"
          "%d/qbittorrent-password"
        ]
        ++ lib.concatMap (mapping: [
          "--qbt-path-remote"
          mapping.remote
          "--qbt-path-local"
          mapping.local
        ]) cfg.qbittorrent.pathMappings
      );
    in
    {
      systemd = {
        services.slskd-import = {
          description = "Import completed downloads into beets";
          after = [
            "local-fs.target"
            "beets-config.service"
          ];
          wants = [ "beets-config.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = cfg.user;
            Group = cfg.group;
            TimeoutStartSec = "infinity";
            NoNewPrivileges = true;
            PrivateTmp = true;
            LoadCredential = lib.optional (
              cfg.qbittorrent != null
            ) "qbittorrent-password:${cfg.qbittorrent.passwordFile}";
            ExecStart = lib.escapeShellArgs (
              [
                "${pkgs.python3}/bin/python3"
                (toString script)
              ]
              ++ sourceArgs
              ++ [
                "--beet"
                "${cfg.beetsPackage}/bin/beet"
                "--settle"
                (toString cfg.settleSeconds)
              ]
              ++ qbtArgs
              ++ lib.optional cfg.topLevelAlbums "--top-level-albums"
              ++ lib.optionals (cfg.staleAfter > 0) [
                "--stale-after"
                (toString cfg.staleAfter)
              ]
            );
          };
        };

        timers.slskd-import = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitInactiveSec = "${toString cfg.interval}s";
          };
        };

        tmpfiles.rules = tmpfilesRules;
      };
    };
}
