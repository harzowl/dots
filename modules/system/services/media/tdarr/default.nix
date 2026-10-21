let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "tdarr";
    image = "docker.io/haveagitgat/tdarr@sha256:5b3b8d4e54f41738d12ff71705cf8eb8e90fcbcc05209c331853aef119879992";
    ports = [ "8265:8265" ];
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "media"
    "tdarr"
  ];
  description = "Tdarr transcode server and node (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/tdarr";
        description = "Host directory for the server database, node config and logs.";
      };

      cacheDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/cache/tdarr";
        description = "Host directory for the transcode cache (mounted at `/temp`).";
      };

      mediaDir = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/media";
        description = "Host directory holding the media library (mounted at `/media`).";
      };

      dataOwner = lib.mkOption {
        type = lib.types.str;
        default = "1000:1000";
        description = ''
          Numeric `user:group` that owns the server, config and log directories.
          The image runs as `PUID`/`PGID`, but docker creates missing bind mounts
          owned by root, which the container then cannot write.
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) config lib;
      spec = cfg // {
        volumes = [
          "${cfg.dataDir}/server:/app/server"
          "${cfg.dataDir}/configs:/app/configs"
          "${cfg.dataDir}/logs:/app/logs"
          "${cfg.cacheDir}:/temp"
          "${cfg.mediaDir}:/media"
        ];
        settings = cfg.settings // {
          PUID = lib.head (lib.splitString ":" cfg.dataOwner);
          PGID = lib.elemAt (lib.splitString ":" cfg.dataOwner) 1;
          TZ = config.dots.system.core.timezone;
        };
        # Tdarr reads these camelCase names; the settings option would upper-snake them.
        extraOptions = cfg.extraOptions ++ [
          "--env"
          "internalNode=true"
          "--env"
          "nodeID=${config.dots.system.core.hostname}"
          "--env"
          "inContainer=true"
        ];
      };
    in
    lib.mkMerge [
      (mkDockerService.config {
        inherit spec defaults;
      } args)

      {
        systemd.tmpfiles.rules = map (d: "d '${d}' 0755 ${cfg.dataOwner} - -") [
          "${cfg.dataDir}/server"
          "${cfg.dataDir}/configs"
          "${cfg.dataDir}/logs"
        ];
      }
    ];
}
