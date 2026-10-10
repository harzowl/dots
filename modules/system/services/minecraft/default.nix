# Minecraft (Java edition). Two roles live here:
#
#   * `.enable`        — the server, from the `itzg/minecraft-server` image
#                        (configured entirely through env vars, so `settings`
#                        maps straight onto them: `maxPlayers` -> `MAX_PLAYERS`).
#   * `.router.enable` — the hostname router (`itzg/mc-router`), run on a public
#                        host: it routes by the server address in the Minecraft
#                        handshake, so a backend is reachable ONLY via the names
#                        declared in `routes` (an unmatched address is dropped).
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
      # JVM heap for the server (see the image's MEMORY variable).
      memory = "4G";
      onlineMode = true;
      maxPlayers = 10;
      # Only whitelisted players may join (set `whitelist = [ … ];`).
      enforceWhitelist = true;
    };
  };

  routerDefaults = {
    name = "mc-router";
    image = "itzg/mc-router:latest";
    ports = [ 25565 ];
    # `mapping` (-> `MAPPING`) is a comma/newline-delimited
    # `externalHostname=host:port` list, e.g.
    # "mc.example.com=10.10.0.4:25565,203.0.113.10=10.10.0.4:25565".
    # No `default` -> an unmatched server address is dropped.
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

  # Either role may be enabled on its own (the router runs on `edge`, the server
  # on `arcade`).
  when = cfg: cfg.enable || cfg.router.enable;

  toConfig =
    args: cfg:
    let
      lib = args.lib;
    in
    lib.mkMerge [
      (lib.mkIf cfg.enable ((mkDockerService.config { spec = cfg; defaults = serverDefaults; }) args))
      (lib.mkIf cfg.router.enable (
        (mkDockerService.config { spec = cfg.router; defaults = routerDefaults; }) args
      ))
    ];
}
