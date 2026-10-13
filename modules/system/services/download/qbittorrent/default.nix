# qBittorrent — torrent client (LinuxServer image); its WebUI is :8080, served
# with vuetorrent as the alternate WebUI. Only the service's own identity lives
# here; the consumer supplies volumes, the environment (TZ/PUID/PGID) and how
# it is fronted.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "qbittorrent";
    image = "lscr.io/linuxserver/qbittorrent:latest";
    ports = [ "127.0.0.1:8080:8080" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "qbittorrent"
  ];
  description = "qBittorrent client (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      webUiPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          A dotenv file (e.g. the secretspec env path) holding the WebUI password
          under `webUiPasswordKey`. The LinuxServer image has no environment
          variable for it, so the password is seeded into `qBittorrent.conf`'s
          `WebUI\Password_PBKDF2` at boot — never into the Nix store.
        '';
      };

      webUiPasswordKey = lib.mkOption {
        type = lib.types.str;
        default = "QBITTORRENT_PASSWORD";
        description = "Key to read the WebUI password from in `webUiPasswordFile`.";
      };

      webUiUsername = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "WebUI username to seed alongside the password.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      # The config lives in a `qBittorrent` folder inside the /config mount, so
      # the path is derived from the volume instead of being restated.
      configMount = lib.findFirst (
        v: lib.hasSuffix ":/config" v || lib.hasSuffix ":/config:ro" v
      ) null cfg.volumes;
      configFile =
        if configMount == null then
          null
        else
          "${lib.removeSuffix ":ro" (lib.removeSuffix ":/config" configMount)}/qBittorrent/qBittorrent.conf";

      seed = cfg.webUiPasswordFile != null && configFile != null;
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg;
        inherit defaults;
      } args)

      (lib.mkIf seed {
        systemd.services."${cfg.name}-webui-password" = {
          description = "Seed qBittorrent's WebUI password from a secret";
          wantedBy = [ "multi-user.target" ];
          after = [ "docker-${cfg.name}.service" ];
          wants = [ "docker-${cfg.name}.service" ];
          # Re-run whenever the secret store is re-materialised (a secret edit).
          partOf = [ "secretspec.service" ];
          path = [
            pkgs.python3
            pkgs.systemd
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            set -eu
            result="$(${pkgs.python3}/bin/python3 ${./seed-webui-password.py} \
              --env-file ${lib.escapeShellArg cfg.webUiPasswordFile} \
              --env-key ${lib.escapeShellArg cfg.webUiPasswordKey} \
              --conf ${lib.escapeShellArg configFile} \
              --username ${lib.escapeShellArg (if cfg.webUiUsername == null then "" else cfg.webUiUsername)})"
            if [ "$result" = changed ]; then
              systemctl try-restart docker-${cfg.name}.service
            fi
          '';
        };
      })
    ];
}
