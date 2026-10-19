let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "qbittorrent";
    image = "lscr.io/linuxserver/qbittorrent:latest";
    ports = [ "127.0.0.1:8080:8080" ];
    openFirewall = false;
    dockerMods = [ "ghcr.io/vuetorrent/vuetorrent-lsio-mod:latest" ];
  };

  webUiPreferences = [
    "WebUI\\AlternativeUIEnabled=true"
    "WebUI\\RootFolder=/vuetorrent"
  ];
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

      configMount = lib.findFirst (
        v: lib.hasSuffix ":/config" v || lib.hasSuffix ":/config:ro" v
      ) null cfg.volumes;
      configFile =
        if configMount == null then
          null
        else
          "${lib.removeSuffix ":ro" (lib.removeSuffix ":/config" configMount)}/qBittorrent/qBittorrent.conf";

      scriptArgs = lib.concatMapStrings (a: " " + a) (
        [
          "--conf"
          (lib.escapeShellArg configFile)
        ]
        ++ lib.optionals (cfg.webUiPasswordFile != null) [
          "--env-file"
          (lib.escapeShellArg cfg.webUiPasswordFile)
          "--env-key"
          (lib.escapeShellArg cfg.webUiPasswordKey)
        ]
        ++ [
          "--username"
          (lib.escapeShellArg (if cfg.webUiUsername == null then "" else cfg.webUiUsername))
        ]
        ++ lib.concatMap (p: [
          "--pref"
          (lib.escapeShellArg p)
        ]) webUiPreferences
      );
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg;
        inherit defaults;
      } args)

      (lib.mkIf (configFile != null) {
        systemd.services."${cfg.name}-webui" = {
          description = "Seed qBittorrent's WebUI settings";
          wantedBy = [ "multi-user.target" ];
          after = [ "docker-${cfg.name}.service" ];
          wants = [ "docker-${cfg.name}.service" ];
          partOf = [ "secretspec.service" ];
          path = [
            pkgs.python3
            pkgs.systemd
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            set -eu
            if [ "$(${pkgs.python3}/bin/python3 ${./seed-webui.py}${scriptArgs} --check)" = changed ]; then
              # qBittorrent rewrites its config when it exits, so it must not be
              # running while the file is written or the change is clobbered on
              # its next stop.
              systemctl stop docker-${cfg.name}.service || true
              ${pkgs.python3}/bin/python3 ${./seed-webui.py}${scriptArgs}
              systemctl start docker-${cfg.name}.service
            fi
          '';
        };
      })
    ];
}
