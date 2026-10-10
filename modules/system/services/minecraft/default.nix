# Minecraft server (Java edition), run from the `itzg/minecraft-server` image,
# which is configured entirely through environment variables — so `settings` maps
# straight onto them (`maxPlayers` -> `MAX_PLAYERS`).
let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;
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
    {
      container = lib.mkOption {
        type = lib.types.submodule mkDockerService.options;
        default = {
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
            # Only whitelisted players may join (the `whitelist` setting below).
            enforceWhitelist = true;
          };
        };
        description = ''
          The container spec (see dots' `mkDockerService`); defaults to the
          `itzg/minecraft-server` image with a PAPER server on `:25565`, world in
          `/var/lib/minecraft`, 10 players and a 4G heap. Override `settings`
          with any of the image's env vars in camelCase.
        '';
      };
    };

  toConfig = args: cfg: mkDockerService.config cfg.container args;
}
