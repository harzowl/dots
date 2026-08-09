{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dots.system.programs.shell.zsh;
in
{
  options.dots.system.programs.shell.zsh = {
    enable = lib.mkEnableOption "zsh shell";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zsh;
      description = "The zsh package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      package = cfg.package;
    };
  };
}
