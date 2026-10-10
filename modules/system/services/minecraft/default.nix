# Minecraft server (Java edition), run from the `itzg/minecraft-server` image,
# which is configured entirely through environment variables — so `settings` maps
# straight onto them (`maxPlayers` -> `MAX_PLAYERS`, `whitelist` -> `WHITELIST`).
let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;

  defaults = {
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
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "minecraft"
  ];
  description = "Minecraft server (OCI container)";

  options =
    { lib, ... }:
    mkDockerService.options { inherit lib defaults; };

  toConfig = args: cfg: mkDockerService.config { spec = cfg; inherit defaults; } args;
}
