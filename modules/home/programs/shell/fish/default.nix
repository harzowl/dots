{ root ? [ "dots" "home" ] }:
{ config, lib, pkgs, loginShell ? null, ... }:
let
  path = root ++ [ "programs" "shell" "fish" ];
  cfg = lib.getAttrFromPath path config;
  fishTheme = import ../../../../../lib/fishTheme.nix;
in
{
  options = lib.setAttrByPath path {
    # Self-enable when the user's login shell is fish (loginShell is provided by
    # the dots home-manager integration); overridable.
    enable = lib.mkEnableOption "fish shell" // { default = loginShell == "fish"; };

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

    xdg.configFile."fish/conf.d/dots-theme.fish".text = fishTheme;
  };
}
