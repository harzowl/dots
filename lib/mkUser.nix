# Declares a user once, wiring up both their NixOS (system) and home-manager
# config:
#
#   imports = [ (mkUser {
#     name = "harzo";
#     system = { role = "admin"; shell = "fish"; keys = [ ... ]; };
#     home = { programs.monitoring.bottom.enable = true; };
#   }) ];
#
# `system` is forwarded to `dots.system.users.<name>` (so it creates the NixOS
# user and enables the login shell), `home` to `dots.home.users.<name>` (the
# per-user home-manager config). Both sides are optional.
{
  name,
  system ? { },
  home ? { },
}:
{ ... }:
{
  dots.system.users.${name} = system;
  dots.home.users.${name} = home;
}
