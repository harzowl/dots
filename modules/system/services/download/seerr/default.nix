let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "seerr";
    image = "ghcr.io/seerr-team/seerr:latest";
    ports = [ "127.0.0.1:5055:5055" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "seerr"
  ];
  description = "Seerr media request manager (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      configDir = lib.mkOption {
        type = lib.types.str;
        description = "Host directory for Seerr's configuration (mounted at `/app/config`).";
      };

      dataOwner = lib.mkOption {
        type = lib.types.str;
        default = "1000:1000";
        description = ''
          Numeric `user:group` that owns `configDir`. The image runs as UID/GID
          1000, but docker creates a missing bind mount owned by root, which the
          container then cannot write.
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg // {
          volumes = [ "${cfg.configDir}:/app/config" ] ++ cfg.volumes;
          extraOptions = [ "--init" ] ++ cfg.extraOptions;
        };
        inherit defaults;
      } args)

      {
        # Docker creates a missing bind-mount source as root, before the
        # container can write to it; own it before every start.
        systemd.services."${cfg.backend}-${cfg.name}".preStart = ''
          ${pkgs.coreutils}/bin/install -d -m 0755 '${cfg.configDir}'
          ${pkgs.coreutils}/bin/chown ${cfg.dataOwner} '${cfg.configDir}'
        '';
      }
    ];
}
