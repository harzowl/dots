{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dots.home.programs.shell.zsh;
in
{
  options.dots.home.programs.shell.zsh = {
    enable = lib.mkEnableOption "zsh shell";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zsh;
      description = "The zsh package to use.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Additional settings forwarded verbatim to zsh shell";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      package = cfg.package;
    }
    // cfg.settings;
  };
}
