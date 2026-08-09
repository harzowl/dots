{ config, lib, ... }:
let
  cfg = config.dots.home.programs.shell.fish;
in
{
  options.dots.home.programs.shell.fish = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Settings forwarded verbatim to home-manager's programs.fish.";
  };

  config = lib.mkIf (cfg != { }) {
    programs.fish = cfg;
  };
}
