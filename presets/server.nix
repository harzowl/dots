{ config, lib, ... }:
{
  dots.system = {
    core.enable = lib.mkDefault true;

    memory.zram.enable = lib.mkDefault true;

    security.sudo.enable = lib.mkDefault true;
    services.access.openssh.enable = lib.mkDefault true;

    nix = {
      # `nh clean` owns store GC; only fall back to nix's own GC if it is off.
      garbageCollector.enable = lib.mkDefault (!config.dots.system.programs.nix.nh.clean.enable);

      autoOptimiseStore = lib.mkDefault true;
    };

    programs = {
      shell.starship.enable = lib.mkDefault true;

      nix.nh = {
        enable = lib.mkDefault true;

        clean = {
          enable = lib.mkDefault true;
          extraArgs = lib.mkDefault "--keep-since 30d";
        };
      };
    };
  };
}
