{ config, lib, ... }:
let
  cfg = config.dots.system.core;
in
{
  options.dots.system.core.domain = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "The domain of the host (sets networking.domain, used for DNS search and the FQDN).";
  };

  config.networking.domain = lib.mkIf (cfg.enable && cfg.domain != null) cfg.domain;
}
