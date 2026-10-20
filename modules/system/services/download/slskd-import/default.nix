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
  description = "Import completed slskd downloads into beets";

  options =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      completeDir = lib.mkOption {
        type = lib.types.str;
        description = "Completed-download root, with one directory per Soulseek user.";
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
          Incomplete trees are always eligible. In the complete tree only albums
          already marked duplicate or error are removed, plus empty directories,
          so an album waiting to be imported is never removed. Set to 0 to
          disable.
        '';
      };

      incompleteDir = lib.mkOption {
        type = lib.types.str;
        description = "slskd's incomplete-download root, used to skip albums still in progress.";
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
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      script = pkgs.writeText "slskd-import.py" (builtins.readFile ./slskd-import.py);
    in
    {
      systemd = {
        services.slskd-import = {
          description = "Import completed slskd downloads into beets";
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
            ExecStart = lib.escapeShellArgs (
              [
                "${pkgs.python3}/bin/python3"
                (toString script)
                "--complete"
                cfg.completeDir
                "--incomplete"
                cfg.incompleteDir
                "--beet"
                "${cfg.beetsPackage}/bin/beet"
                "--settle"
                (toString cfg.settleSeconds)
              ]
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

        tmpfiles.rules = [
          "d '${cfg.completeDir}' 2775 ${cfg.user} ${cfg.group} -"
          "d '${cfg.incompleteDir}' 2775 ${cfg.user} ${cfg.group} -"
        ];
      };
    };
}
