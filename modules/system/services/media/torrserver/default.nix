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
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib;
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
    ];
}
