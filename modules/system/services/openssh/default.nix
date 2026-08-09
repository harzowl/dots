{ config, lib, ... }:
let
  cfg = config.dots.system.services.openssh;
in
{
  options.dots.system.services.openssh.enable = lib.mkEnableOption "OpenSSH server.";

  config = lib.mkIf cfg.enable {
    services.openssh.enable = cfg.enable;
  };
}
