# fish, defined once for both targets. NixOS and home-manager both expose
# `programs.fish`; the theme file lands in the system conf.d on the system target
# and in the user's config on the home target.
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
  fishTheme = builtins.readFile ./dots-theme.fish;
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "shell"
    "fish"
  ];
  description = "fish shell";

  options =
    { lib, pkgs, ... }:
    {
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

  home =
    args: cfg:
    {
      programs.fish = {
        enable = true;
        package = cfg.package;
      }
      // cfg.settings;

      xdg.configFile."fish/conf.d/dots-theme.fish".text = fishTheme;
    };

  system =
    args: cfg:
    {
      programs.fish = {
        enable = true;
        package = cfg.package;
      }
      // cfg.settings;

      environment.etc."fish/conf.d/dots-theme.fish".text = fishTheme;
    };
}
