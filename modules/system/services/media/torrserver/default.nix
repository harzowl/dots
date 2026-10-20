let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "torrserver";
    image = "ghcr.io/yourok/torrserver:latest";
    ports = [ "8090:8090" ];
    openFirewall = true;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "media"
    "torrserver"
  ];
  description = "TorrServer torrent streaming backend (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/torrserver";
        description = "Host directory for TorrServer's state (mounted at `/opt/ts`).";
      };

      apiUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:8090";
        description = "TorrServer URL the settings service uses.";
      };

      torrServerSettings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "TorrServer API settings applied on every start.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
      settingsService = "${cfg.name}-settings";
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg // {
          volumes = [ "${cfg.dataDir}:/opt/ts" ] ++ cfg.volumes;
        };
        inherit defaults;
      } args)

      {
        systemd.tmpfiles.rules = [
          "d '${cfg.dataDir}' 0755 root root -"
        ];
      }

      (lib.mkIf (cfg.torrServerSettings != { }) {
        systemd.services.${settingsService} = {
          description = "Apply TorrServer settings";
          wantedBy = [ "multi-user.target" ];
          after = [ "docker-${cfg.name}.service" ];
          requires = [ "docker-${cfg.name}.service" ];
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.jq
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -eu
            url=${lib.escapeShellArg cfg.apiUrl}
            for _ in $(seq 1 60); do
              if curl -fsS -o /dev/null "$url/echo"; then
                break
              fi
              sleep 1
            done

            current=$(curl -fsS -X POST "$url/settings" -H 'Content-Type: application/json' -d '{"action":"get"}')
            merged=$(printf '%s' "$current" | jq --argjson overrides '${builtins.toJSON cfg.torrServerSettings}' '. * $overrides')
            printf '%s' "$merged" | jq -c '{action:"set",sets:.}' | curl -fsS -X POST "$url/settings" -H 'Content-Type: application/json' --data @-
          '';
        };
      })
    ];
}
