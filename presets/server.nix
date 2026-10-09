# The `server` preset: a baseline bundle for headless servers.
#
# Every value is a `lib.mkDefault`, so a host can override any single option by
# setting it normally:
#
#   { imports = [ dots.nixosModules.presetServer ];
#     dots.system.core.timezone = "Europe/Warsaw"; }
#
# Deliberately personal values (hostname, domain, timezone, users) are NOT here,
# so a consumer can layer its own preset on top (see my-dots' `personal` preset,
# which imports `dots.nixosModules.presetServer`). Node- or role-specific services (mail,
# proxy, …) do not belong in a preset either.
{ config, lib, ... }:
{
  dots.system = {
    core.enable = lib.mkDefault true;

    security.sudo.enable = lib.mkDefault true;
    services.access.openssh.enable = lib.mkDefault true;

    nix = {
      # `nh clean` owns store GC; only fall back to nix's own GC if it is off.
      garbageCollector.enable = lib.mkDefault (!config.dots.system.programs.nix.nh.clean.enable);

      # Hard-link identical store files to save space.
      autoOptimiseStore = lib.mkDefault true;
    };

    programs = {
      shell.starship.enable = lib.mkDefault true;

      nix.nh = {
        enable = lib.mkDefault true;

        clean = {
          enable = lib.mkDefault true;
          # Keep ~30 days of generations (the previous nix.gc policy).
          extraArgs = lib.mkDefault "--keep-since 30d";
        };
      };
    };
  };
}
