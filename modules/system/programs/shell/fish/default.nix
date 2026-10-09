{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dots.system.programs.shell.fish;
  fishTheme = import ../../../../../lib/fishTheme.nix;
in
{
  options.dots.system.programs.shell.fish = {
    enable = lib.mkEnableOption "fish shell";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.fish;
      description = "The fish package to use.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Additional settings forwarded verbatim to fish shell";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.fish = {
      enable = true;
      package = cfg.package;
    }
    // cfg.settings;

    environment.etc."fish/conf.d/dots-theme.fish".text = fishTheme;
  };
}
