{ root ? [ "dots" "home" ] }:
{ config, lib, pkgs, loginShell ? null, ... }:
let
  path = root ++ [ "programs" "shell" "zsh" ];
  cfg = lib.getAttrFromPath path config;
in
{
  options = lib.setAttrByPath path {
    # Self-enable when the user's login shell is zsh (loginShell is provided by
    # the dots home-manager integration); overridable.
    enable = lib.mkEnableOption "zsh shell" // { default = loginShell == "zsh"; };

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
