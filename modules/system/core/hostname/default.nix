{ config, lib, ... }:
let
  cfg = config.dots.system.core;
in
{
  options.dots.system.core.hostname = lib.mkOption {
    type = lib.types.str;
    description = "The hostname of the system.";
  };

  config.networking.hostName = lib.mkIf cfg.enable cfg.hostname;
}
