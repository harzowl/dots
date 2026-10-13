# `/tmp` on tmpfs: one toggle for a RAM-backed temp dir that is empty on every
# boot (no stale files, no disk writes, no clean-up job). Despite the name,
# `reservedSize` is a cap, not a reservation — tmpfs pages are allocated from
# RAM on demand — but pick one the host can actually back, since a runaway
# `/tmp` can still exhaust RAM.
#
#   dots.system.core.tmp = { useTmpfs = true; reservedSize = "512M"; };
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
      # mkDefault: a host may still set boot.tmp.* directly (or override the
      # option above), e.g. to cap the size below its RAM.
      tmpfsSize = lib.mkDefault cfg.tmp.reservedSize;
      cleanOnBoot = lib.mkDefault true;
    };
  };
}
