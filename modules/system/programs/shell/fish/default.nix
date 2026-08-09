{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dots.system.programs.shell.fish;
in
{
  options.dots.system.programs.shell.fish = {
    enable = lib.mkEnableOption "fish shell";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.fish;
      description = "The fish package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.fish = {
      enable = true;
      package = cfg.package;
    };
  };
}
