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

      localPlugins = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Directory of local flow plugins, mounted at `LocalFlowPlugins`.";
      };

      patches = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Patches applied to the local flow-plugin tree before it is mounted.";
      };

      abAv1 = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Mount the static ab-av1 binary at `/usr/local/bin/ab-av1`.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) config lib pkgs;

      patchedPlugins =
        if cfg.localPlugins == null then
          null
        else
          pkgs.runCommand "tdarr-local-plugins" { nativeBuildInputs = [ pkgs.patch ]; } ''
            cp -r ${cfg.localPlugins} $out
            chmod -R u+w $out
            ${lib.concatMapStringsSep "\n" (p: "patch -p1 -d $out < ${p}") cfg.patches}
          '';

      spec = cfg // {
        volumes = [
          "${cfg.dataDir}/server:/app/server"
          "${cfg.dataDir}/configs:/app/configs"
          "${cfg.dataDir}/logs:/app/logs"
          "${cfg.cacheDir}:/temp"
          "${cfg.mediaDir}:/media"
        ]
        ++ lib.optional cfg.abAv1 "${pkgs.pkgsStatic.ab-av1}/bin/ab-av1:/usr/local/bin/ab-av1:ro"
        ++ lib.optional (
          patchedPlugins != null
        ) "${patchedPlugins}:/app/server/Tdarr/Plugins/FlowPlugins/LocalFlowPlugins:ro";
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
