let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;

  serverDefaults = {
    name = "minecraft";
    image = "itzg/minecraft-server:latest";
    ports = [ 25565 ];
    volumes = [ "/var/lib/minecraft:/data" ];
    settings = {
      # Accepting the Minecraft EULA is required for the image to start.
      eula = true;
      type = "PAPER";
      version = "LATEST";
      memory = "4G";
      onlineMode = true;
      maxPlayers = 10;
      enforceWhitelist = true;
    };
  };

  routerDefaults = {
    name = "mc-router";
    image = "itzg/mc-router:latest";
    ports = [ 25565 ];
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "games"
    "minecraft"
  ];
  description = "Minecraft server (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options {
      inherit lib;
      defaults = serverDefaults;
    })
    // {
      router = lib.mkOption {
        type = lib.types.submodule {
          options =
            (mkDockerService.options {
              inherit lib;
              defaults = routerDefaults;
            })
            // {
              enable = lib.mkEnableOption "the Minecraft hostname router (mc-router)";
            };
        };
        default = { };
        description = "Hostname router (run on the public host; routes by the handshake's server address).";
      };
    };

  when = cfg: cfg.enable || cfg.router.enable;

  toConfig =
    args: cfg:
    let
      inherit (args) lib;
    in
    lib.mkMerge [
      (lib.mkIf cfg.enable (
        (mkDockerService.config {
          spec = cfg;
          defaults = serverDefaults;
        })
          args
      ))
      (lib.mkIf cfg.router.enable (
        (mkDockerService.config {
          spec = cfg.router;
          defaults = routerDefaults;
        })
          args
      ))
    ];
}
