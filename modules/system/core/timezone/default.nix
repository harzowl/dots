{ config, lib, ... }:
let
  cfg = config.dots.system.core;
in
{
  options.dots.system.core.timezone = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "The time zone of the host (sets `time.timeZone`, e.g. \"Europe/Warsaw\").";
  };

  config.time.timeZone = lib.mkIf (cfg.enable && cfg.timezone != null) cfg.timezone;
}
