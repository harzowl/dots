{ config, lib, ... }:
let
  cfg = config.dots.system.core;
in
{
  options.dots.system.core.tmp = {
    useTmpfs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Mount `/tmp` as a tmpfs (RAM-backed and wiped on boot).";
    };

    reservedSize = lib.mkOption {
      type = lib.types.str;
      default = "256M";
      description = "Maximum size of the `/tmp` tmpfs (any systemd size, e.g. \"512M\" or \"50%\").";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.tmp.useTmpfs) {
    boot.tmp = {
      useTmpfs = true;
      tmpfsSize = lib.mkDefault cfg.tmp.reservedSize;
      cleanOnBoot = lib.mkDefault true;
    };
  };
}
